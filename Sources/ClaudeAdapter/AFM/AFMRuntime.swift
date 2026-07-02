import Foundation
import FoundationModels
import AgentBridgeCore
import AFMBackend

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
    private let sharedBackend: FoundationModelsBackend

    init(sharedBackend: FoundationModelsBackend = FoundationModelsBackend()) {
        self.model = .default
        self.sharedBackend = sharedBackend
    }

    var availability: SystemLanguageModel.Availability { model.availability }

    func newSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    func generate(
        instructions: String,
        conversation: String,
        options: GenerationOptions,
        conversationKey: String? = nil,
        sessionFingerprint: String? = nil,
        resultingSessionFingerprint: String? = nil,
        incrementalPrompt: String? = nil
    ) async throws -> GenerateResult {
        let result = try await sharedBackend.generate(AgentGenerationRequest(
            model: ModelRegistry.primaryModel,
            messages: [
                AgentMessage(role: .system, text: instructions),
                AgentMessage(role: .user, text: conversation),
            ],
            maximumOutputTokens: options.maximumResponseTokens,
            temperature: options.temperature,
            conversationKey: conversationKey,
            contextFingerprint: sessionFingerprint,
            resultingContextFingerprint: resultingSessionFingerprint,
            incrementalMessages: incrementalPrompt.map { [AgentMessage(role: .user, text: $0)] }
        ))
        return GenerateResult(
            text: result.text,
            inputTokens: result.inputTokens ?? 0,
            outputTokens: result.outputTokens ?? 0,
            stopReason: "end_turn"
        )
    }

    func generateStructured(
        instructions: String,
        conversation: String,
        tools: [ToolDefinition],
        options: GenerationOptions,
        toolChoice: AgentToolChoice = .auto,
        decisionContext: String? = nil
    ) async throws -> StructuredResult {
        let result = try await sharedBackend.generate(AgentGenerationRequest(
            model: ModelRegistry.primaryModel,
            messages: [
                AgentMessage(role: .system, text: instructions),
                AgentMessage(role: .user, text: conversation),
            ],
            tools: tools.map(\.agentDefinition),
            maximumOutputTokens: options.maximumResponseTokens,
            temperature: options.temperature,
            decisionContext: decisionContext,
            toolChoice: toolChoice,
            executionStrategy: .adaptive
        ))
        let call = result.toolCalls.first

        return StructuredResult(
            text: Self.normalizedOptional(result.text),
            toolName: call?.name,
            toolArguments: call?.argumentsJSON ?? "{}",
            inputTokens: result.inputTokens ?? 0,
            outputTokens: result.outputTokens ?? 0,
            stopReason: call == nil ? "end_turn" : "tool_use"
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "nil", trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }
}

extension SystemLanguageModel.Availability {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
