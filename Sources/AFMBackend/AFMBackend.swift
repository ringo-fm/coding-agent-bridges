import AgentBridgeCore
import Foundation
import FoundationModels

public protocol AgentModelBackend: Sendable {
    var contextSize: Int { get }
    var capabilities: AgentRuntimeCapabilities { get }
    func status() -> AFMBackendStatus
    func countTokens(_ text: String) async -> Int
    func generate(_ request: AgentGenerationRequest) async throws -> AgentGenerationResult
    func stream(_ request: AgentGenerationRequest) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}

public enum AFMBackendStatus: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public final class FoundationModelsBackend: AgentModelBackend, Sendable {
    private let model: SystemLanguageModel
    private let sessionPool: AFMSessionPool

    public init(sessionPoolConfiguration: AFMSessionPoolConfiguration = .auto()) {
        model = .default
        sessionPool = AFMSessionPool(model: model, configuration: sessionPoolConfiguration)
    }

    public var contextSize: Int { model.contextSize }

    public var capabilities: AgentRuntimeCapabilities {
        let exactTokenCounting: Bool
        if #available(macOS 26.4, *) { exactTokenCounting = true } else { exactTokenCounting = false }
        return AgentRuntimeCapabilities(
            contextSize: model.contextSize,
            exactTokenCounting: exactTokenCounting
        )
    }

    public func status() -> AFMBackendStatus {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence is not enabled")
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "device is not eligible")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "model assets are not ready")
        case .unavailable:
            return .unavailable(reason: "unknown availability failure")
        @unknown default:
            return .unavailable(reason: "unknown availability failure")
        }
    }

    public func countTokens(_ text: String) async -> Int {
        guard !text.isEmpty else { return 0 }
        if #available(macOS 26.4, *), let exact = try? await model.tokenCount(for: text) {
            return exact
        }
        return ContextPlanner.estimateTokens(text)
    }

    public func generate(_ request: AgentGenerationRequest) async throws -> AgentGenerationResult {
        try requireAvailable()
        let components = Self.render(request.messages)
        do {
            try Task.checkCancellation()
            // Count input tokens concurrently with generation to reduce latency.
            async let inputTokens = countTokens(components.instructions + "\n\n" + components.prompt)
            if !request.tools.isEmpty, request.toolChoice != .none {
                var result = try await AFMToolExecution.generate(
                    model: model,
                    request: request,
                    instructions: components.instructions,
                    prompt: components.prompt,
                    options: Self.options(request)
                )
                let outputTokens = await countTokens(result.text + result.toolCalls.map(\.argumentsJSON).joined())
                result = AgentGenerationResult(
                    text: result.text,
                    toolCalls: result.toolCalls,
                    inputTokens: await inputTokens,
                    outputTokens: outputTokens
                )
                return result
            }
            let text: String
            if let key = request.conversationKey {
                let incremental = request.incrementalMessages.map(Self.render)?.prompt
                text = try await sessionPool.respond(
                    key: key,
                    fingerprint: request.contextFingerprint ?? ConversationFingerprint.digest(components.instructions),
                    resultingFingerprint: request.resultingContextFingerprint,
                    instructions: components.instructions,
                    fullPrompt: components.prompt,
                    incrementalPrompt: incremental,
                    options: Self.options(request)
                )
            } else {
                let session = Self.session(model: model, instructions: components.instructions)
                text = try await session.respond(to: components.prompt, options: Self.options(request)).content
            }
            try Task.checkCancellation()
            // Use heuristic for output tokens to avoid a second model call after generation
            let outputTokens = ContextPlanner.estimateTokens(text)
            return AgentGenerationResult(
                text: text,
                inputTokens: await inputTokens,
                outputTokens: outputTokens
            )
        } catch is CancellationError {
            throw AgentBackendError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error, contextSize: contextSize)
        } catch {
            throw AgentBackendError.generationFailed(String(describing: error))
        }
    }

    public func stream(
        _ request: AgentGenerationRequest
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try requireAvailable()
        if !request.tools.isEmpty, request.toolChoice != .none {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let result = try await self.generate(request)
                        for call in result.toolCalls { continuation.yield(.toolCall(call)) }
                        if !result.text.isEmpty { continuation.yield(.textDelta(result.text)) }
                        continuation.yield(.completed(result))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let components = Self.render(request.messages)
        let session = Self.session(model: model, instructions: components.instructions)
        let responseStream = session.streamResponse(to: components.prompt, options: Self.options(request))
        let box = AFMResponseStreamBox(stream: responseStream, session: session)
        let inputTokens = await countTokens(components.instructions + "\n\n" + components.prompt)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var previous = ""
                do {
                    for try await snapshot in box.stream {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        let delta = current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : current
                        previous = current
                        if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                    }
                    let outputTokens = await self.countTokens(previous)
                    continuation.yield(.completed(AgentGenerationResult(
                        text: previous,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentBackendError.cancelled)
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error, contextSize: self.contextSize))
                } catch {
                    continuation.finish(throwing: AgentBackendError.generationFailed(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func requireAvailable() throws {
        guard case .available = status() else {
            if case .unavailable(let reason) = status() {
                throw AgentBackendError.unavailable(reason)
            }
            throw AgentBackendError.unavailable("unknown availability failure")
        }
    }

    private static func render(_ messages: [AgentMessage]) -> (instructions: String, prompt: String) {
        let instructions = messages.filter { $0.role == .system || $0.role == .developer }
            .map(\.text).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system && $0.role != .developer }
            .map { "[\($0.role.rawValue)] \($0.text)" }.joined(separator: "\n")
        return (instructions, prompt.isEmpty ? "[user] Continue." : prompt)
    }

    private static func session(model: SystemLanguageModel, instructions: String) -> LanguageModelSession {
        instructions.isEmpty
            ? LanguageModelSession(model: model)
            : LanguageModelSession(model: model, instructions: instructions)
    }

    private static func options(_ request: AgentGenerationRequest) -> GenerationOptions {
        var options = GenerationOptions()
        options.temperature = request.temperature
        options.maximumResponseTokens = request.maximumOutputTokens
        if let topP = request.topP {
            options.sampling = .random(probabilityThreshold: topP)
        }
        return options
    }

    private static func map(
        _ error: LanguageModelSession.GenerationError,
        contextSize: Int
    ) -> AgentBackendError {
        switch error {
        case .exceededContextWindowSize:
            return .contextTooLarge(limit: contextSize)
        case .assetsUnavailable:
            return .unavailable("model assets are unavailable")
        default:
            return .generationFailed(error.errorDescription ?? String(describing: error))
        }
    }
}

private final class AFMResponseStreamBox: @unchecked Sendable {
    let stream: LanguageModelSession.ResponseStream<String>
    let session: LanguageModelSession

    init(stream: LanguageModelSession.ResponseStream<String>, session: LanguageModelSession) {
        self.stream = stream
        self.session = session
    }
}
