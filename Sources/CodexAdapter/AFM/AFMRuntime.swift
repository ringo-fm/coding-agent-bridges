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
    public let toolContext: String?
    public let priorToolCalls: [CapturedToolCall]
    public let toolStepCount: Int
    public let maxToolSteps: Int
    public let finalizeAfterToolOutput: Bool
    public let directToolResultAnswer: String?

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
        incrementalPrompt: String? = nil,
        toolContext: String? = nil,
        priorToolCalls: [CapturedToolCall] = [],
        toolStepCount: Int = 0,
        maxToolSteps: Int = 6,
        finalizeAfterToolOutput: Bool = false,
        directToolResultAnswer: String? = nil
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
        self.toolContext = toolContext
        self.priorToolCalls = priorToolCalls
        self.toolStepCount = toolStepCount
        self.maxToolSteps = max(1, maxToolSteps)
        self.finalizeAfterToolOutput = finalizeAfterToolOutput
        self.directToolResultAnswer = directToolResultAnswer
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

enum CodexToolLoopPolicy {
    static func stopReason(
        stepCount: Int,
        maxSteps: Int,
        proposed: CapturedToolCall? = nil,
        priorCalls: [CapturedToolCall] = []
    ) -> String? {
        if stepCount >= max(1, maxSteps) {
            return "The coding tool step limit was reached. Summarize the results already obtained, state what remains, and do not request another tool."
        }
        guard let proposed else { return nil }
        let proposedArguments = canonicalArguments(proposed.argumentsJSON)
        let duplicateCount = priorCalls.filter {
            $0.name == proposed.name && canonicalArguments($0.argumentsJSON) == proposedArguments
        }.count
        if duplicateCount >= 2 {
            return "The same tool call has already been attempted twice. Summarize the available result or failure and stop without requesting another tool."
        }
        return nil
    }

    private static func canonicalArguments(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: canonical, encoding: .utf8) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
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
            if let answer = request.directToolResultAnswer {
                return AFMGenerateResult(text: answer, finishReason: "stop")
            }
            if request.finalizeAfterToolOutput {
                let text = try await finalText(
                    request: request,
                    options: options,
                    reason: "The requested read-only inspection succeeded. Answer the current request from the tool output and do not request another tool."
                )
                return AFMGenerateResult(text: text, finishReason: "stop")
            }
            if let reason = CodexToolLoopPolicy.stopReason(
                stepCount: request.toolStepCount,
                maxSteps: request.maxToolSteps
            ) {
                let text = try await finalText(
                    request: request,
                    options: options,
                    reason: reason
                )
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
            let sanitized = Self.sanitizeToolArguments(arguments, toolName: selected.names[0])
            let proposed = CapturedToolCall(name: selected.names[0], argumentsJSON: sanitized)
            if let reason = CodexToolLoopPolicy.stopReason(
                stepCount: request.toolStepCount,
                maxSteps: request.maxToolSteps,
                proposed: proposed,
                priorCalls: request.priorToolCalls
            ) {
                let text = try await finalText(
                    request: request,
                    options: options,
                    reason: reason
                )
                return AFMGenerateResult(text: text, finishReason: "stop")
            }
            selected.capture(argumentsJSON: sanitized)
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

        if let answer = request.directToolResultAnswer {
            return AsyncThrowingStream { continuation in
                continuation.yield(AFMStreamSnapshot(cumulativeText: answer, isFinal: true))
                continuation.finish()
            }
        }

        if request.finalizeAfterToolOutput {
            return try await textStream(
                request: request,
                options: options,
                additionalInstructions: "The requested read-only inspection succeeded. Answer the current request from the tool output and do not request another tool.",
                promptOverride: request.toolContext
            )
        }

        if let reason = CodexToolLoopPolicy.stopReason(
            stepCount: request.toolStepCount,
            maxSteps: request.maxToolSteps
        ) {
            return try await textStream(
                request: request,
                options: options,
                additionalInstructions: reason,
                promptOverride: request.toolContext
            )
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
        let sanitized = Self.sanitizeToolArguments(arguments, toolName: selected.names[0])
        let proposed = CapturedToolCall(name: selected.names[0], argumentsJSON: sanitized)
        if let reason = CodexToolLoopPolicy.stopReason(
            stepCount: request.toolStepCount,
            maxSteps: request.maxToolSteps,
            proposed: proposed,
            priorCalls: request.priorToolCalls
        ) {
            return try await textStream(
                request: request,
                options: options,
                additionalInstructions: reason,
                promptOverride: request.toolContext
            )
        }
        selected.capture(argumentsJSON: sanitized)
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
        options: GenerationOptions,
        additionalInstructions: String? = nil,
        promptOverride: String? = nil
    ) async throws -> AsyncThrowingStream<AFMStreamSnapshot, Error> {
        let session = makeSession(instructions: Self.joinInstructions(request.instructions, additionalInstructions))
        let text: String
        do {
            let generated = try await session.respond(to: promptOverride ?? request.prompt, options: options).content
            text = try Self.requireNonEmptyText(generated)
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
        let routingPrompt = Self.boundedRoutingPrompt(request.toolContext ?? request.incrementalPrompt ?? request.prompt)
        if Self.simpleFileCreation(routingPrompt) != nil,
           let exec = registry.selecting(name: "exec_command") {
            return (nil, exec)
        }
        let routingInstructions = registry.compactCatalog + """


        If the request requires reading files, inspecting the repository, running commands, editing, or another advertised action, select exactly one tool and set text to nil. After a tool output, request another tool only when it is required to finish the current request; otherwise provide the final answer in text. Use image-oriented tools only for actual image file formats. Never claim a tool was executed.
        """
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
            if Self.requiresToolAction(routingPrompt),
               let fallback = Self.actionTool(for: routingPrompt, in: registry) {
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
        let argumentPrompt = Self.boundedRoutingPrompt(request.toolContext ?? request.incrementalPrompt ?? request.prompt)
        if toolName == "exec_command", let deterministic = Self.deterministicExecArguments(argumentPrompt) {
            return deterministic
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
        throw BridgeError.generationFailed("failed to generate valid tool arguments")
    }

    private func finalText(
        request: AFMGenerateRequest,
        options: GenerationOptions,
        reason: String
    ) async throws -> String {
        let session = makeSession(instructions: Self.joinInstructions(request.instructions, reason))
        do {
            let generated = try await session.respond(
                to: request.toolContext ?? request.prompt,
                options: options
            ).content
            return try Self.requireNonEmptyText(generated)
        } catch is CancellationError {
            throw BridgeError.generationCancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.generationFailed(String(describing: error))
        }
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

    private static func deterministicExecArguments(_ prompt: String) -> String? {
        guard !prompt.contains("Tool output ") else { return nil }
        let lower = prompt.lowercased()
        let command: String
        if let creation = simpleFileCreation(prompt) {
            command = "printf '%s\\n' \(shellQuote(creation.content)) > \(shellQuote(creation.path)) && sed -n '1,5p' \(shellQuote(creation.path))"
        } else if lower.contains("run pwd") || lower.contains("execute pwd") {
            command = "pwd"
        } else {
            let pattern = #"(?<![A-Za-z0-9_./-])([A-Za-z0-9_./-]+\.(?:swift|md|json|toml|ya?ml|rs|go|tsx?|jsx?|py|c|h))(?![A-Za-z0-9_./-])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: prompt,
                    range: NSRange(prompt.startIndex..., in: prompt)
                  ),
                  let range = Range(match.range(at: 1), in: prompt) else {
                return nil
            }
            let path = String(prompt[range])
            guard !path.contains("..") else { return nil }
            command = "sed -n '1,220p' " + shellQuote(path)
        }
        let object: [String: Any] = [
            "cmd": command,
            "yield_time_ms": 10_000,
            "max_output_tokens": 6_000,
            "sandbox_permissions": "use_default"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func simpleFileCreation(_ prompt: String) -> (path: String, content: String)? {
        let lower = prompt.lowercased()
        guard lower.contains("create") || prompt.contains("作成") else { return nil }
        let pathPattern = #"([A-Za-z0-9_./-]+\.(?:txt|md|json|toml|ya?ml|swift|rs|go|tsx?|jsx?|py))"#
        let contentPattern = #"(?i)containing exactly\s+([A-Za-z0-9_.-]+)"#
        guard let pathRegex = try? NSRegularExpression(pattern: pathPattern),
              let pathMatch = pathRegex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let pathRange = Range(pathMatch.range(at: 1), in: prompt),
              let contentRegex = try? NSRegularExpression(pattern: contentPattern),
              let contentMatch = contentRegex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let contentRange = Range(contentMatch.range(at: 1), in: prompt) else {
            return nil
        }
        let path = String(prompt[pathRange])
        guard !path.contains("..") else { return nil }
        return (path, String(prompt[contentRange]))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private static func requireNonEmptyText(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        throw BridgeError.generationFailed("Apple Foundation Models returned an empty response")
    }

    private static func joinInstructions(_ first: String?, _ second: String?) -> String? {
        let values = [first, second].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: "\n\n")
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
        let half = byteLimit / 2
        return String(decoding: value.utf8.prefix(half), as: UTF8.self)
            + "\n[...middle content omitted...]\n"
            + String(decoding: value.utf8.suffix(half), as: UTF8.self)
    }

    private static func requiresToolAction(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        guard !lower.contains("[tool_output"), !lower.contains("tool output ") else { return false }
        let mutationMarkers = [
            "create", "edit", "change", "fix", "implement", "write", "delete", "rename",
            "作成", "編集", "変更", "修正", "実装", "削除"
        ]
        let containsFilePath = lower.range(
            of: #"[a-z0-9_./-]+\.(swift|md|txt|json|toml|ya?ml|rs|go|tsx?|jsx?|py|c|h)"#,
            options: .regularExpression
        ) != nil
        return mentionsRepository(lower)
            || containsFilePath
            || mutationMarkers.contains { lower.contains($0) }
    }

    private static func mentionsRepository(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let markers = [
            "repository", "repo", "codebase", "file", "source", "inspect", "summarize",
            "リポジトリ", "コードベース", "ファイル", "ソース", "調べ", "確認", "要約"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func actionTool(
        for prompt: String,
        in registry: BridgedToolRegistry
    ) -> BridgedToolRegistry? {
        let lower = prompt.lowercased()
        let mutationMarkers = ["create", "edit", "change", "fix", "implement", "write", "delete", "rename", "作成", "編集", "変更", "修正", "実装", "削除"]
        if mutationMarkers.contains(where: { lower.contains($0) }),
           let patch = registry.selecting(name: "apply_patch") {
            return patch
        }
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
