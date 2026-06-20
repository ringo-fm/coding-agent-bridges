import Foundation
import AgentBridgeCore
import AFMBackend
import Hummingbird
import HummingbirdCore
import NIOCore
import HTTPTypes
import struct Logging.Logger

/// Shared services made available to every route handler.
public struct BridgeServices: Sendable {
    public let afm: AFMRuntime
    public let store: ResponseStore
    public let config: BridgeConfig
    public let profile: CompatibilityProfile
    public let logger: Logger
    public let contextLedger: any ContextLedger

    public init(
        afm: AFMRuntime,
        store: ResponseStore,
        config: BridgeConfig,
        profile: CompatibilityProfile,
        logger: Logger,
        contextLedger: any ContextLedger = InMemoryContextLedger()
    ) {
        self.afm = afm
        self.store = store
        self.config = config
        self.profile = profile
        self.logger = logger
        self.contextLedger = contextLedger
    }
}

/// Builds the Hummingbird router with all MVP endpoints and the auth middleware.
public enum Routes {
    public static func build(services: BridgeServices) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.add(middleware: AuthMiddleware<BasicRequestContext>(expectedToken: services.config.authToken))
        mount(on: router.group(), services: services)
        return router
    }

    public static func mount(
        on group: RouterGroup<BasicRequestContext>,
        services: BridgeServices,
        includeSharedRoutes: Bool = true
    ) {
        let router = group

        if includeSharedRoutes {
            // GET /health
            router.get("health") { _, _ in
                let availability = services.afm.availability()
                let payload: [String: String] = [
                    "status": availability.isAvailable ? "ok" : "unavailable",
                    "model": SupportedModels.canonical,
                    "available": availability.isAvailable ? "true" : "false"
                ]
                var headers = HTTPFields()
                headers[.contentType] = "application/json; charset=utf-8"
                return Response(status: .ok, headers: headers, body: .init(byteBuffer: try encodeBuffer(payload)))
            }

            // GET /v1/models
            router.get("v1/models") { _, _ in
                var headers = HTTPFields()
                headers[.contentType] = "application/json; charset=utf-8"
                return Response(status: .ok, headers: headers, body: .init(byteBuffer: try encodeBuffer(ModelsList.default)))
            }
        }

        // POST /v1/responses
        router.post("v1/responses") { request, context in
            let body: ResponsesCreateRequest
            do {
                body = try await request.decode(as: ResponsesCreateRequest.self, context: context)
            } catch {
                services.logger.error("failed to decode request body: \(error.localizedDescription)")
                throw BridgeError.invalidRequest("could not decode JSON body: \(error.localizedDescription)")
            }

            services.logger.info("POST /v1/responses model=\(body.model) stream=\(body.stream ?? false) input_items=\(body.input.asItems.count)")

            guard SupportedModels.isSupported(body.model) else {
                throw BridgeError.unsupportedModel(body.model)
            }

            try rejectUnsupportedInputTypes(body, flags: services.profile.flags)

            var normalized = InputNormalizer.normalize(body, flags: services.profile.flags)

            let responseID = newID(prefix: "resp_afm_")

            let limit = services.afm.contextSize
            let prepared: PreparedCodexContext
            do {
                prepared = try await CodexContextPlanner.prepare(
                    request: body,
                    normalized: normalized,
                    responseID: responseID,
                    contextSize: limit,
                    ledger: services.contextLedger
                )
            } catch {
                throw BridgeError.internalError("context planning failed: \(error)")
            }
            let prompt = prepared.prompt
            let estTokens = prepared.plan.estimatedTokens
            if prepared.plan.truncated {
                services.logger.warning(
                    "prompt_truncated: ~\(estTokens) tokens (budget \(prepared.plan.budget), limit \(limit))"
                )
                normalized.diagnostics.markTruncated("prompt", detail: "fit \(limit)-token context")
            }
            // If even after truncation we're still over (shouldn't happen with
            // hard-truncate phase), bail out with a clear error.
            if estTokens > limit {
                services.logger.warning("context_too_large: ~\(estTokens) tokens > limit \(limit)")
                throw BridgeError.contextTooLarge(inputTokens: estTokens, limit: limit)
            }

            let stream = body.stream ?? false

            // Map tools to AFM BridgedTools when function-call is enabled.
            var toolRegistry: BridgedToolRegistry? = nil
            if services.profile.flags.functionCall, let tools = body.tools, !tools.isEmpty {
                toolRegistry = ToolMapper.map(tools)
                if let toolRegistry {
                    services.logger.info("tools: \(toolRegistry.afmTools.count) tool(s) mapped")
                }
            }

            let afmRequest = AFMGenerateRequest(
                responseID: responseID,
                model: body.model,
                instructions: prepared.instructions,
                prompt: prompt,
                stream: stream,
                temperature: body.temperature,
                maxOutputTokens: body.max_output_tokens ?? PromptBuilder.defaultOutputReserve,
                topP: body.top_p,
                toolRegistry: toolRegistry,
                conversationKey: prepared.sessionKey,
                sessionFingerprint: prepared.sessionFingerprint,
                resultingSessionFingerprint: prepared.resultingSessionFingerprint,
                incrementalPrompt: prepared.incrementalPrompt
            )

            if stream {
                return try await streamingResponse(
                    request: request,
                    services: services,
                    afmRequest: afmRequest,
                    responseID: responseID,
                    model: body.model,
                    diagnostics: normalized.diagnostics,
                    contextConversationID: prepared.conversation.id
                )
            } else {
                return try await nonStreamingResponse(
                    services: services,
                    afmRequest: afmRequest,
                    responseID: responseID,
                    model: body.model,
                    diagnostics: &normalized.diagnostics,
                    contextConversationID: prepared.conversation.id
                )
            }
        }

        // GET /v1/responses/{id}
        router.get("v1/responses/:id") { _, context in
            let id = context.parameters.get("id", as: String.self) ?? context.parameters.get("id")
            guard let id else {
                throw BridgeError.invalidRequest("missing response id in path")
            }
            guard let response = await services.store.get(id) else {
                throw BridgeError.invalidRequest("response '\(id)' not found")
            }
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: try encodeBuffer(response)))
        }

    }
}

public func mountCodexRoutes(
    on router: RouterGroup<BasicRequestContext>,
    host: String,
    port: Int,
    authToken: String,
    sharedBackend: FoundationModelsBackend,
    contextLedger: any ContextLedger,
    logger: Logger
) {
    let config = BridgeConfig(
        host: host,
        port: port,
        authToken: authToken,
        logLevel: .warning,
        debug: false,
        contextMode: .memory
    )
    Routes.mount(on: router, services: BridgeServices(
        afm: AFMRuntime(sharedBackend: sharedBackend),
        store: ResponseStore(),
        config: config,
        profile: .codexTools,
        logger: logger,
        contextLedger: contextLedger
    ), includeSharedRoutes: false)
}

// MARK: - Non-streaming response

private func nonStreamingResponse(
    services: BridgeServices,
    afmRequest: AFMGenerateRequest,
    responseID: String,
    model: String,
    diagnostics: inout Diagnostics,
    contextConversationID: String
) async throws -> Response {
    let result = try await services.afm.generate(afmRequest)

    let inputTokens = await services.afm.inputTokenCount(for: afmRequest.prompt) ?? OutputMapper.estimateTokens(text: afmRequest.prompt)
    let enriched = AFMGenerateResult(
        text: result.text,
        inputTokens: inputTokens,
        outputTokens: result.outputTokens,
        finishReason: result.finishReason,
        toolCalls: result.toolCalls
    )

    let response = OutputMapper.toResponsesObject(
        responseID: responseID,
        model: model,
        result: enriched,
        diagnostics: &diagnostics
    )

    await services.store.store(response)
    try? await services.contextLedger.append(
        ContextSegment(
            id: "assistant-" + responseID,
            kind: .recentConversation,
            text: "[assistant] \(result.text)",
            sourceTurnID: responseID,
            metadata: ["role": "assistant"]
        ),
        to: contextConversationID
    )

    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    if diagnostics.estimatedUsage {
        headers[.init(afmUsageEstimatedHeader)!] = "true"
    }
    if services.config.debug, !diagnostics.isEmpty {
        injectDiagnosticsHeader(&headers, diagnostics)
    }
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: try encodeBuffer(response)))
}

// MARK: - Streaming response (SSE)

private func streamingResponse(
    request: Request,
    services: BridgeServices,
    afmRequest: AFMGenerateRequest,
    responseID: String,
    model: String,
    diagnostics: Diagnostics,
    contextConversationID: String
) async throws -> Response {
    let createdAt = Int(Date().timeIntervalSince1970)
    let messageID = newID(prefix: "msg_afm_")
    let logger = services.logger
    let afm = services.afm
    let store = services.store

    var headers = HTTPFields()
    headers[.contentType] = "text/event-stream; charset=utf-8"
    headers[.cacheControl] = "no-cache"
    headers[.connection] = "keep-alive"
    if diagnostics.estimatedUsage {
        headers[.init(afmUsageEstimatedHeader)!] = "true"
    }

    return Response(
        status: .ok,
        headers: headers,
        body: .init { writer in
            let sse = SSEWriter()
            let inProgress = OutputMapper.toInProgressObject(responseID: responseID, model: model, createdAt: createdAt)

            try await sse.write(.responseCreated(inProgress), to: &writer)
            try await sse.write(.responseInProgress(inProgress), to: &writer)

            let item = ResponsesOutputItem(
                id: messageID,
                type: "message",
                status: .in_progress,
                role: "assistant",
                content: []
            )
            try await sse.write(.responseOutputItemAdded(outputIndex: 0, item: item), to: &writer)

            let part = ResponsesOutputContent(type: "output_text", text: "")
            try await sse.write(.responseContentPartAdded(outputIndex: 0, contentIndex: 0, part: part), to: &writer)

            do {
                try await request.body.consumeWithCancellationOnInboundClose { _ in
                    var lastLen = 0
                    var fullText = ""
                    do {
                        let stream = try await afm.stream(afmRequest)
                        for try await snapshot in stream {
                            let cumulative = snapshot.cumulativeText
                            if cumulative.count > lastLen {
                                let delta = String(cumulative.dropFirst(lastLen))
                                fullText = cumulative
                                lastLen = cumulative.count
                                try await sse.write(
                                    .responseOutputTextDelta(outputIndex: 0, contentIndex: 0, delta: delta),
                                    to: &writer
                                )
                            }
                        }
                    } catch let error as BridgeError {
                        let failed = OutputMapper.toFailedObject(responseID: responseID, model: model, error: error, createdAt: createdAt)
                        try? await sse.write(.responseFailed(failed), to: &writer)
                        try? await sse.write(.error(error.errorObject), to: &writer)
                        return
                    } catch is CancellationError {
                        return
                    }

                    try await sse.write(.responseOutputTextDone(outputIndex: 0, contentIndex: 0, text: fullText), to: &writer)

                    // Emit the completed message item — Codex reads the final
                    // assistant text from the `item` field of this event.
                    let doneItem = ResponsesOutputItem.assistantMessage(id: messageID, text: fullText)
                    try await sse.write(.responseOutputItemDone(outputIndex: 0, item: doneItem), to: &writer)

                    // Emit function_call items for any tools AFM called.
                    let toolCalls = afmRequest.toolRegistry?.drainAllCapturedCalls() ?? []
                    for (idx, call) in toolCalls.enumerated() {
                        let callID = newID(prefix: "call_afm_")
                        let fcID = newID(prefix: "fc_afm_")
                        let fcItem = ResponsesOutputItem.functionCall(
                            id: fcID, callID: callID, name: call.name, arguments: call.argumentsJSON
                        )
                        let outputIdx = idx + 1
                        try await sse.write(.responseOutputItemAdded(outputIndex: outputIdx, item: fcItem), to: &writer)
                        try await sse.write(.responseOutputItemDone(outputIndex: outputIdx, item: fcItem), to: &writer)
                    }

                    var diags = diagnostics
                    let inputTokens = await afm.inputTokenCount(for: afmRequest.prompt) ?? OutputMapper.estimateTokens(text: afmRequest.prompt)
                    let outputTokens = await afm.inputTokenCount(for: fullText) ?? OutputMapper.estimateTokens(text: fullText)
                    let completed = OutputMapper.toCompletedObject(
                        responseID: responseID,
                        model: model,
                        text: fullText,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        createdAt: createdAt,
                        diagnostics: &diags
                    )
                    try await sse.write(.responseCompleted(completed, endTurn: true), to: &writer)
                    await store.store(completed)
                    try? await services.contextLedger.append(
                        ContextSegment(
                            id: "assistant-" + responseID,
                            kind: .recentConversation,
                            text: "[assistant] \(fullText)",
                            sourceTurnID: responseID,
                            metadata: ["role": "assistant"]
                        ),
                        to: contextConversationID
                    )
                }
            } catch is CancellationError {
                logger.debug("stream client disconnected: \(responseID)")
            }
            try await writer.finish(nil)
        }
    )
}

// MARK: - Helpers

private let afmUsageEstimatedHeader = "x-afm-usage-estimated"
private let afmDiagnosticsHeader = "x-afm-diagnostics"

/// Reject requests that contain hard-unsupported input content types (images,
/// files) so the client gets a clear 400 instead of silent dropping.
private func rejectUnsupportedInputTypes(_ request: ResponsesCreateRequest, flags: FeatureFlags) throws {
    for item in request.input.asItems {
        guard let parts = item.content else { continue }
        for part in parts {
            switch part.type {
            case "input_image":
                if !flags.imageInput {
                    throw BridgeError.unsupportedInputType("input_image")
                }
            case "input_file":
                if !flags.fileInput {
                    throw BridgeError.unsupportedInputType("input_file")
                }
            default:
                break
            }
        }
    }
}

/// Encode diagnostics into a response header for debug builds.
private func injectDiagnosticsHeader(_ headers: inout HTTPFields, _ diagnostics: Diagnostics) {
    let summary = diagnostics.summary
    if !summary.isEmpty {
        headers[.init(afmDiagnosticsHeader)!] = summary
    }
}
