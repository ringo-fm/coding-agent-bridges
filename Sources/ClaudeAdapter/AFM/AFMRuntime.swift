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

    init() {
        self.model = .default
        self.sharedBackend = FoundationModelsBackend()
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
        options: GenerationOptions
    ) async throws -> StructuredResult {
        let catalog = ToolMapper.buildCompactToolCatalog(tools: tools)
        let routingInstructions = instructions + "\n\n" + catalog
        let routingSession = newSession(instructions: routingInstructions)
        let routing = try await routingSession.respond(
            to: conversation,
            generating: ToolRoutingDecision.self,
            options: options
        ).content

        let text = Self.normalizedOptional(routing.text)
        let toolName = Self.normalizedOptional(routing.toolName)
        var toolArgs = "{}"
        var argumentPrompt = ""
        if let toolName, let selected = tools.first(where: { $0.name == toolName }) {
            let selectedPrompt = ToolMapper.buildSelectedToolPrompt(selected)
            argumentPrompt = conversation + "\n\nGenerate arguments for the selected tool '\(toolName)'."
            var retryFeedback = ""
            for attempt in 0..<3 {
                let argumentSession = newSession(instructions: instructions + "\n\n" + selectedPrompt)
                let candidate = try await argumentSession.respond(
                    to: argumentPrompt + retryFeedback,
                    generating: SelectedToolArguments.self,
                    options: options
                ).content.arguments
                let (parsed, validationError) = ToolMapper.validateGeneratedToolCall(
                        name: toolName,
                        argumentsJSON: candidate,
                        against: tools
                    )
                if parsed != nil {
                    toolArgs = candidate
                    break
                } else {
                    guard attempt < 2 else {
                        throw NSError(
                            domain: "ClaudeAdapter.ToolArguments",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: validationError]
                        )
                    }
                    retryFeedback = "\n\nThe previous arguments were invalid: \(validationError) Return only a valid JSON object matching the schema."
                }
            }
        }

        let inputTokens = await TokenCounter.countInput(
            model: model,
            system: routingInstructions,
            conversation: conversation + argumentPrompt
        )
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
