import Foundation
import FoundationModels

struct GenerateResult: Sendable {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let stopReason: String
}

struct StructuredResult: Sendable {
    let text: String?
    let toolName: String?
    let toolArguments: String
    let inputTokens: Int
    let outputTokens: Int
    let stopReason: String

    var hasToolCall: Bool { toolName != nil }
}

final class AFMRuntime: Sendable {
    let model: SystemLanguageModel

    init() { self.model = .default }

    var availability: SystemLanguageModel.Availability { model.availability }

    func newSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    func generate(instructions: String, conversation: String, options: GenerationOptions) async throws -> GenerateResult {
        let session = newSession(instructions: instructions)
        let response = try await session.respond(to: conversation, options: options)
        let text = response.content
        let inputTokens = await TokenCounter.countInput(model: model, system: instructions, conversation: conversation)
        let outputTokens = await TokenCounter.countOutput(model: model, text: text)
        return GenerateResult(text: text, inputTokens: inputTokens, outputTokens: outputTokens, stopReason: "end_turn")
    }

    func generateStructured(instructions: String, conversation: String, options: GenerationOptions) async throws -> StructuredResult {
        let session = newSession(instructions: instructions)
        let response = try await session.respond(to: conversation, generating: AgentResponse.self, options: options)
        let agentResp = response.content

        let text = agentResp.text
        let toolName = agentResp.toolCall?.name
        let toolArgs = agentResp.toolCall?.arguments ?? "{}"

        let inputTokens = await TokenCounter.countInput(model: model, system: instructions, conversation: conversation)
        let outputDesc = [text, toolName, toolArgs].compactMap { $0 }.joined(separator: " ")
        let outputTokens = await TokenCounter.countOutput(model: model, text: outputDesc)
        let stopReason = toolName != nil ? "tool_use" : "end_turn"

        return StructuredResult(
            text: text,
            toolName: toolName,
            toolArguments: toolArgs,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            stopReason: stopReason
        )
    }
}

extension SystemLanguageModel.Availability {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

