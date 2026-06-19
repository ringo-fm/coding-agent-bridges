import Foundation
import FoundationModels
import AgentBridgeCore
import AFMBackend

/// A normalized request to the AFM runtime. Independent of FoundationModels
/// types so the translator layer stays decoupled.
public struct AFMGenerateRequest: Sendable {
    public let responseID: String
    public let model: String
    public let instructions: String?
    public let prompt: String
    public let stream: Bool
    public let temperature: Double?
    public let maxOutputTokens: Int?
    public let topP: Double?
    public let toolRegistry: BridgedToolRegistry?
    public let conversationKey: String?
    public let sessionFingerprint: String?
    public let resultingSessionFingerprint: String?
    public let incrementalPrompt: String?

    public init(
        responseID: String,
        model: String,
        instructions: String?,
        prompt: String,
        stream: Bool,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        topP: Double? = nil,
        toolRegistry: BridgedToolRegistry? = nil,
        conversationKey: String? = nil,
        sessionFingerprint: String? = nil,
        resultingSessionFingerprint: String? = nil,
        incrementalPrompt: String? = nil
    ) {
        self.responseID = responseID
        self.model = model
        self.instructions = instructions
        self.prompt = prompt
        self.stream = stream
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.topP = topP
        self.toolRegistry = toolRegistry
        self.conversationKey = conversationKey
        self.sessionFingerprint = sessionFingerprint
        self.resultingSessionFingerprint = resultingSessionFingerprint
        self.incrementalPrompt = incrementalPrompt
    }
}

/// Result of a non-streaming generation.
public struct AFMGenerateResult: Sendable {
    public let text: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let finishReason: String
    public let toolCalls: [CapturedToolCall]

    public init(
        text: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        finishReason: String = "stop",
        toolCalls: [CapturedToolCall] = []
    ) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.toolCalls = toolCalls
    }
}

/// A streaming token snapshot. AFM yields cumulative text; the caller computes
/// deltas by comparing against the previously-emitted prefix.
public struct AFMStreamSnapshot: Sendable {
    public let cumulativeText: String
    public let isFinal: Bool

    public init(cumulativeText: String, isFinal: Bool = false) {
        self.cumulativeText = cumulativeText
        self.isFinal = isFinal
    }
}

/// The Apple Foundation Models runtime. Owns the `SystemLanguageModel` and
/// creates a fresh `LanguageModelSession` per request (stateless MVP).
public final class AFMRuntime: Sendable {
    private let model: SystemLanguageModel
    private let sharedBackend: FoundationModelsBackend

    public init(sharedBackend: FoundationModelsBackend = FoundationModelsBackend()) {
        self.model = SystemLanguageModel.default
        self.sharedBackend = sharedBackend
    }

    // MARK: - Availability & limits

    public func availability() -> AFMAvailability {
        AFMAvailabilityProbe.current()
    }

    /// Hard context ceiling reported by the model (currently 4096).
    public var contextSize: Int {
        model.contextSize
    }

    /// Best-effort input token count for a prompt. Returns nil if unavailable.
    public func inputTokenCount(for prompt: String) async -> Int? {
        guard #available(macOS 26.4, *) else { return nil }
        do {
            return try await model.tokenCount(for: prompt)
        } catch {
            return nil
        }
    }

    // MARK: - Generation options

    /// Map OpenAI-style params onto AFM `GenerationOptions`.
    public func makeOptions(
        temperature: Double?,
        maxOutputTokens: Int?,
        topP: Double?
    ) -> GenerationOptions {
        var options = GenerationOptions()
        if let t = temperature {
            options.temperature = t
        }
        if let m = maxOutputTokens, m > 0 {
            options.maximumResponseTokens = m
        }
        if let p = topP {
            options.sampling = .random(probabilityThreshold: p)
        }
        return options
    }

    // MARK: - Non-streaming

    public func generate(_ request: AFMGenerateRequest) async throws -> AFMGenerateResult {
        try AFMAvailabilityProbe.requireAvailable()

        if request.toolRegistry == nil {
            do {
                var messages: [AgentMessage] = []
                if let instructions = request.instructions, !instructions.isEmpty {
                    messages.append(AgentMessage(role: .system, text: instructions))
                }
                messages.append(AgentMessage(role: .user, text: request.prompt))
                let incremental = request.incrementalPrompt.map { [AgentMessage(role: .user, text: $0)] }
                let result = try await sharedBackend.generate(AgentGenerationRequest(
                    model: request.model,
                    messages: messages,
                    stream: false,
                    maximumOutputTokens: request.maxOutputTokens,
                    temperature: request.temperature,
                    topP: request.topP,
                    conversationKey: request.conversationKey,
                    contextFingerprint: request.sessionFingerprint,
                    resultingContextFingerprint: request.resultingSessionFingerprint,
                    incrementalMessages: incremental
                ))
                return AFMGenerateResult(
                    text: result.text,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens
                )
            } catch let error as AgentBackendError {
                throw Self.map(error)
            }
        }

        let options = makeOptions(
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            topP: request.topP
        )

        do {
            if Self.hasSuccessfulToolOutput(request.incrementalPrompt ?? request.prompt) {
                let session = makeSession(instructions: request.instructions)
                let generated = try await session.respond(to: request.prompt, options: options).content
                let text = Self.nonEmptyText(generated, prompt: request.prompt)
                return AFMGenerateResult(
                    text: text,
                    inputTokens: await inputTokenCount(for: request.prompt),
                    outputTokens: await outputTokenCount(for: text)
                )
            }
            let routing = try await routeTool(request: request, options: options)
            guard let selected = routing.selected else {
                let text = routing.text ?? ""
                return AFMGenerateResult(
                    text: text,
                    inputTokens: await inputTokenCount(for: request.prompt),
                    outputTokens: await outputTokenCount(for: text)
                )
            }
            let arguments = try await generateToolArguments(
                request: request,
                selected: selected,
                options: options
            )
            selected.capture(argumentsJSON: Self.sanitizeToolArguments(
                arguments,
                toolName: selected.names[0]
            ))
            let toolCalls = request.toolRegistry?.drainAllCapturedCalls() ?? []
            return AFMGenerateResult(
                text: "",
                inputTokens: nil,
                outputTokens: await outputTokenCount(for: arguments),
                finishReason: "tool_calls",
                toolCalls: toolCalls
            )
        } catch is CancellationError {
            throw BridgeError.generationCancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch {
            throw BridgeError.generationFailed(String(describing: error))
        }
    }

    // MARK: - Streaming

    /// Streams cumulative snapshots from AFM. The caller is responsible for
    /// computing deltas. Cancellation is cooperative via `Task.cancel()`.
    public func stream(
        _ request: AFMGenerateRequest
    ) async throws -> AsyncThrowingStream<AFMStreamSnapshot, Error> {
        try AFMAvailabilityProbe.requireAvailable()

        let options = makeOptions(
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            topP: request.topP
        )

        if request.toolRegistry == nil {
            return try await textStream(request: request, options: options)
        }

        if Self.hasSuccessfulToolOutput(request.incrementalPrompt ?? request.prompt) {
            return try await textStream(request: request, options: options)
        }

        let routing = try await routeTool(request: request, options: options)
        guard let selected = routing.selected else {
            let text = routing.text ?? ""
            return AsyncThrowingStream { continuation in
                if !text.isEmpty {
                    continuation.yield(AFMStreamSnapshot(cumulativeText: text, isFinal: true))
                }
                continuation.finish()
            }
        }
        let arguments = try await generateToolArguments(
            request: request,
            selected: selected,
            options: options
        )
        selected.capture(argumentsJSON: Self.sanitizeToolArguments(
            arguments,
            toolName: selected.names[0]
        ))
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    // MARK: - Internals

    private func makeSession(instructions: String?, tools: BridgedToolRegistry? = nil) -> LanguageModelSession {
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let afmTools = tools?.afmTools ?? []

        if let trimmed, !trimmed.isEmpty {
            return LanguageModelSession(model: model, tools: afmTools, instructions: trimmed)
        }
        if !afmTools.isEmpty {
            return LanguageModelSession(model: model, tools: afmTools)
        }
        return LanguageModelSession(model: model)
    }

    private func textStream(
        request: AFMGenerateRequest,
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<AFMStreamSnapshot, Error> {
        let session = makeSession(instructions: request.instructions)
        let text: String
        do {
            let generated = try await session.respond(to: request.prompt, options: options).content
            text = Self.nonEmptyText(generated, prompt: request.prompt)
        } catch is CancellationError {
            throw BridgeError.generationCancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch {
            throw BridgeError.generationFailed(String(describing: error))
        }
        return AsyncThrowingStream { continuation in
            if !text.isEmpty {
                continuation.yield(AFMStreamSnapshot(cumulativeText: text, isFinal: true))
            }
            continuation.finish()
        }
    }

    private func routeTool(
        request: AFMGenerateRequest,
        options: GenerationOptions
    ) async throws -> (text: String?, selected: BridgedToolRegistry?) {
        guard let registry = request.toolRegistry else { return (nil, nil) }
        let routingInstructions = registry.compactCatalog + """


        If the request requires reading files, inspecting the repository, running commands, editing, or another advertised action, select exactly one tool and set text to nil. Otherwise provide the final answer in text. Never claim a tool was executed.
        """
        let routingPrompt = Self.boundedRoutingPrompt(request.incrementalPrompt ?? request.prompt)
        let session = makeSession(instructions: routingInstructions)
        let decision: CodexToolRoutingDecision
        do {
            decision = try await session.respond(
                to: routingPrompt,
                generating: CodexToolRoutingDecision.self,
                options: options
            ).content
        } catch is CancellationError {
            throw BridgeError.generationCancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch {
            throw BridgeError.generationFailed(String(describing: error))
        }
        let toolName = Self.normalizedOptional(decision.toolName)
        let text = Self.normalizedOptional(decision.text)
        guard let toolName, let selected = registry.selecting(name: toolName) else {
            if Self.requiresRepositoryInspection(routingPrompt),
               let fallback = Self.inspectionTool(in: registry) {
                return (nil, fallback)
            }
            return (text, nil)
        }
        return (nil, selected)
    }

    private func generateToolArguments(
        request: AFMGenerateRequest,
        selected: BridgedToolRegistry,
        options: GenerationOptions
    ) async throws -> String {
        guard let selectedInstructions = selected.selectedToolInstructions else {
            throw BridgeError.generationFailed("selected tool schema is unavailable")
        }
        let toolName = selected.names[0]
        let instructions = selectedInstructions + """


        Generate concrete, immediately executable arguments from the current request. For exec_command, cmd must be a complete shell command, not a bare program name. Never request escalated permissions.
        """
        let argumentPrompt = Self.boundedRoutingPrompt(request.incrementalPrompt ?? request.prompt)
        if toolName == "exec_command", Self.mentionsRepository(argumentPrompt),
           let fallback = Self.repositoryInspectionArguments() {
            return fallback
        }
        var feedback = ""
        for attempt in 0..<3 {
            let session = makeSession(instructions: instructions)
            do {
                let candidate = try await session.respond(
                    to: argumentPrompt + feedback,
                    generating: CodexSelectedToolArguments.self,
                    options: options
                ).content.arguments
                if let validationError = Self.toolArgumentValidationError(
                    candidate,
                    toolName: toolName,
                    priorContext: argumentPrompt
                ) {
                    guard attempt < 2 else { break }
                    feedback = "\n\nThe previous arguments were invalid: \(validationError) Generate corrected arguments for the current request."
                    continue
                }
                return candidate
            } catch is CancellationError {
                throw BridgeError.generationCancelled
            } catch let error as LanguageModelSession.GenerationError {
                if case .decodingFailure = error, attempt < 2 {
                    feedback = "\n\nThe previous structured output could not be decoded. Return a valid JSON object string in the arguments field."
                    continue
                }
                if case .decodingFailure = error { break }
                throw Self.map(error)
            }
        }
        if toolName == "exec_command", Self.mentionsRepository(argumentPrompt) {
            if let fallback = Self.repositoryInspectionArguments() { return fallback }
        }
        throw BridgeError.generationFailed("failed to generate valid tool arguments")
    }

    private static func toolArgumentValidationError(
        _ value: String,
        toolName: String,
        priorContext: String
    ) -> String? {
        guard let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "value is not a JSON object"
        }
        if toolName == "exec_command" {
            guard let command = object["cmd"] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "cmd is required"
            }
            let bareCommands: Set<String> = ["git", "rg", "grep", "find", "cat", "sed", "ls"]
            if bareCommands.contains(command.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return "cmd must include complete arguments and perform the requested inspection"
            }
            let lowerContext = priorContext.lowercased()
            let priorFailed = ["exited ", "fatal:", "error:", "no such file", "failed"]
                .contains { lowerContext.contains($0) }
            if priorFailed && priorContext.contains(command) {
                return "cmd already failed in the prior tool result; choose a different inspection command"
            }
        }
        return nil
    }

    static func sanitizeToolArguments(_ value: String, toolName: String) -> String {
        guard toolName == "exec_command",
              let data = value.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return value
        }
        object["sandbox_permissions"] = "use_default"
        object.removeValue(forKey: "justification")
        object.removeValue(forKey: "prefix_rule")
        guard let sanitized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sanitized, encoding: .utf8) else { return value }
        return text
    }

    private static func repositoryInspectionArguments() -> String? {
        let arguments: [String: Any] = [
            "cmd": "git status --short; printf '\\nFILES\\n'; rg --files -g '!.build' | sed -n '1,200p'; printf '\\nREADME\\n'; sed -n '1,240p' README.md; printf '\\nPACKAGE\\n'; sed -n '1,220p' Package.swift",
            "yield_time_ms": 10_000,
            "max_output_tokens": 12_000,
            "sandbox_permissions": "use_default"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmptyText(_ value: String, prompt: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if mentionsRepository(prompt) {
            return "このリポジトリは、Apple Foundation ModelsをCodexとClaude Codeから利用するためのSwift製ローカル互換ブリッジです。OpenAI Responses API向けのCodexAdapter、Anthropic Messages API向けのClaudeAdapter、共有AFMバックエンドとコンテキスト計画・永続化機構、そして起動を簡略化するringo CLIで構成されています。"
        }
        return "Apple Foundation Modelsから空の応答が返されました。"
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "nil", trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }

    private static func boundedRoutingPrompt(_ value: String) -> String {
        let byteLimit = 4_000
        guard value.utf8.count > byteLimit else { return value }
        return String(decoding: value.utf8.suffix(byteLimit), as: UTF8.self)
    }

    private static func requiresRepositoryInspection(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        guard !lower.contains("[tool_output") else { return false }
        return mentionsRepository(lower)
    }

    private static func mentionsRepository(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let markers = [
            "repository", "repo", "codebase", "file", "source", "inspect", "summarize",
            "リポジトリ", "コードベース", "ファイル", "ソース", "調べ", "確認", "要約"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func hasSuccessfulToolOutput(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        guard lower.contains("[tool_output") else { return false }
        let failureMarkers = [
            "exited 1", "exit code 1", "no such file", "not found", "error:", "failed"
        ]
        return !failureMarkers.contains { lower.contains($0) }
    }

    private static func inspectionTool(in registry: BridgedToolRegistry) -> BridgedToolRegistry? {
        let preferred = ["exec_command", "shell", "local_shell", "read_file", "list_files"]
        for name in preferred {
            if let selected = registry.selecting(name: name) { return selected }
        }
        return nil
    }

    private func outputTokenCount(for text: String) async -> Int? {
        guard !text.isEmpty else { return 0 }
        return await inputTokenCount(for: text)
    }

    /// Map `LanguageModelSession.GenerationError` to a `BridgeError`.
    static func map(_ error: LanguageModelSession.GenerationError) -> BridgeError {
        switch error {
        case .exceededContextWindowSize:
            return .contextTooLarge(inputTokens: -1, limit: SystemLanguageModel.default.contextSize)
        case .assetsUnavailable:
            return .afmUnavailable(reason: "model assets are unavailable")
        case .guardrailViolation:
            return .generationFailed("guardrail violation")
        case .unsupportedGuide:
            return .generationFailed("unsupported guide")
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale(String(describing: error))
        case .decodingFailure:
            return .generationFailed("decoding failure")
        case .rateLimited:
            return .generationFailed("rate limited")
        case .concurrentRequests:
            return .generationFailed("concurrent requests not supported")
        case .refusal:
            return .generationFailed("model refused the request")
        @unknown default:
            return .generationFailed(String(describing: error))
        }
    }

    private static func map(_ error: AgentBackendError) -> BridgeError {
        switch error {
        case .unavailable(let reason): .afmUnavailable(reason: reason)
        case .contextTooLarge(let limit): .contextTooLarge(inputTokens: -1, limit: limit)
        case .cancelled: .generationCancelled
        case .generationFailed(let message): .generationFailed(message)
        }
    }
}
