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

    public init() {
        self.model = SystemLanguageModel.default
        self.sharedBackend = FoundationModelsBackend()
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

        let session = makeSession(instructions: request.instructions, tools: request.toolRegistry)
        let options = makeOptions(
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            topP: request.topP
        )

        do {
            try Task.checkCancellation()
            let response = try await session.respond(to: request.prompt, options: options)
            try Task.checkCancellation()
            let text = response.content
            let outputTokens = await outputTokenCount(for: text)
            let toolCalls = request.toolRegistry?.drainAllCapturedCalls() ?? []
            return AFMGenerateResult(
                text: text,
                inputTokens: nil,
                outputTokens: outputTokens,
                finishReason: toolCalls.isEmpty ? "stop" : "tool_calls",
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

        let session = makeSession(instructions: request.instructions, tools: request.toolRegistry)
        let options = makeOptions(
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            topP: request.topP
        )

        let stream = session.streamResponse(to: request.prompt, options: options)
        let box = StreamBox(stream: stream, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task<Void, Never> {
                do {
                    for try await snapshot in box.stream {
                        try Task.checkCancellation()
                        continuation.yield(AFMStreamSnapshot(cumulativeText: snapshot.content))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BridgeError.generationCancelled)
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: BridgeError.generationFailed(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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

/// Holds a `ResponseStream` and its `LanguageModelSession` alive across an
/// async boundary. `ResponseStream` is not Sendable, so we use
/// `@unchecked Sendable` (matching the proven pattern in ringo-fm-bridge):
/// the stream is consumed by exactly one iterating Task.
private final class StreamBox: @unchecked Sendable {
    let stream: LanguageModelSession.ResponseStream<String>
    let session: LanguageModelSession
    init(stream: LanguageModelSession.ResponseStream<String>, session: LanguageModelSession) {
        self.stream = stream
        self.session = session
    }
}
