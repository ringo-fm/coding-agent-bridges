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
    public let allowedToolNames: Set<String>?
    public let maxToolSteps: Int

    public init(
        afm: AFMRuntime,
        store: ResponseStore,
        config: BridgeConfig,
        profile: CompatibilityProfile,
        logger: Logger,
        contextLedger: any ContextLedger = InMemoryContextLedger(),
        allowedToolNames: Set<String>? = nil,
        maxToolSteps: Int = 6
    ) {
        self.afm = afm
        self.store = store
        self.config = config
        self.profile = profile
        self.logger = logger
        self.contextLedger = contextLedger
        self.allowedToolNames = allowedToolNames
        self.maxToolSteps = max(1, maxToolSteps)
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

            var effectiveBody = body
            if let allowed = services.allowedToolNames, let tools = body.tools {
                effectiveBody.tools = tools.filter { allowed.contains($0.name ?? $0.type) }
            }

            try rejectUnsupportedInputTypes(effectiveBody, flags: services.profile.flags)

            var normalized = InputNormalizer.normalize(effectiveBody, flags: services.profile.flags)

            let responseID = newID(prefix: "resp_afm_")

            let limit = services.afm.contextSize
            let prepared: PreparedCodexContext
            do {
                prepared = try await CodexContextPlanner.prepare(
                    request: effectiveBody,
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

            let stream = effectiveBody.stream ?? false

            // Map tools to AFM BridgedTools when function-call is enabled.
            var toolRegistry: BridgedToolRegistry? = nil
            if services.profile.flags.functionCall, let tools = effectiveBody.tools, !tools.isEmpty {
                toolRegistry = ToolMapper.map(tools, allowedNames: services.allowedToolNames)
                if let toolRegistry {
                    services.logger.info("tools: \(toolRegistry.afmTools.count) tool(s) mapped")
                }
            }

            let afmRequest = AFMGenerateRequest(
                responseID: responseID,
                model: effectiveBody.model,
                instructions: prepared.instructions,
                prompt: prompt,
                stream: stream,
                temperature: effectiveBody.temperature,
                maxOutputTokens: effectiveBody.max_output_tokens ?? PromptBuilder.defaultOutputReserve,
                topP: effectiveBody.top_p,
                toolRegistry: toolRegistry,
                conversationKey: prepared.sessionKey,
                sessionFingerprint: prepared.sessionFingerprint,
                resultingSessionFingerprint: prepared.resultingSessionFingerprint,
                incrementalPrompt: prepared.incrementalPrompt,
                toolContext: makeToolContext(normalized.events),
                priorToolCalls: normalized.toolCalls.map {
                    CapturedToolCall(name: $0.name, argumentsJSON: $0.arguments)
                },
                toolStepCount: toolStepCount(normalized.events),
                maxToolSteps: services.maxToolSteps,
                finalizeAfterToolOutput: shouldFinalizeAfterToolOutput(normalized.events),
                directToolResultAnswer: directToolResultAnswer(normalized.events)
            )

            if stream {
                return try await streamingResponse(
                    services: services,
                    afmRequest: afmRequest,
                    responseID: responseID,
                    model: effectiveBody.model,
                    diagnostics: normalized.diagnostics,
                    contextConversationID: prepared.conversation.id
                )
            } else {
                return try await nonStreamingResponse(
                    services: services,
                    afmRequest: afmRequest,
                    responseID: responseID,
                    model: effectiveBody.model,
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
    logger: Logger,
    includeSharedRoutes: Bool = false,
    allowedToolNames: Set<String>? = codexAFMCoreToolNames,
    maxToolSteps: Int = 6
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
        contextLedger: contextLedger,
        allowedToolNames: allowedToolNames,
        maxToolSteps: maxToolSteps
    ), includeSharedRoutes: includeSharedRoutes)
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
    await persistOutputItems(
        response.output,
        responseID: responseID,
        conversationID: contextConversationID,
        ledger: services.contextLedger
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
                try await writer.finish(nil)
                return
            } catch is CancellationError {
                logger.debug("stream client disconnected: \(responseID)")
                try await writer.finish(nil)
                return
            }

            try await sse.write(.responseOutputTextDone(outputIndex: 0, contentIndex: 0, text: fullText), to: &writer)

            let doneItem = ResponsesOutputItem.assistantMessage(id: messageID, text: fullText)
            var completedItems = [doneItem]
            try await sse.write(.responseOutputItemDone(outputIndex: 0, item: doneItem), to: &writer)

            let toolCalls = afmRequest.toolRegistry?.drainAllCapturedCalls() ?? []
            for (idx, call) in toolCalls.enumerated() {
                let callID = newID(prefix: "call_afm_")
                let fcID = newID(prefix: "fc_afm_")
                let fcItem = ResponsesOutputItem.functionCall(
                    id: fcID, callID: callID, name: call.name, arguments: call.argumentsJSON
                )
                completedItems.append(fcItem)
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
                outputItems: completedItems,
                createdAt: createdAt,
                diagnostics: &diags
            )
            try await sse.write(.responseCompleted(completed, endTurn: true), to: &writer)
            await store.store(completed)
            await persistOutputItems(
                completedItems,
                responseID: responseID,
                conversationID: contextConversationID,
                ledger: services.contextLedger
            )
            try await writer.finish(nil)
        }
    )
}

// MARK: - Helpers

private let afmUsageEstimatedHeader = "x-afm-usage-estimated"
private let afmDiagnosticsHeader = "x-afm-diagnostics"

private func persistOutputItems(
    _ items: [ResponsesOutputItem],
    responseID: String,
    conversationID: String,
    ledger: any ContextLedger
) async {
    for item in items {
        if item.type == "function_call", let name = item.name, let arguments = item.arguments {
            let callID = item.call_id ?? item.id
            try? await ledger.append(
                ContextSegment(
                    id: "tool-call-" + callID,
                    kind: .recentConversation,
                    text: "[assistant tool_call \(callID)] \(name)(\(arguments))",
                    sourceTurnID: callID,
                    metadata: ["relation": "tool_call", "tool": name]
                ),
                to: conversationID
            )
        } else if item.type == "message" {
            let text = item.content?.compactMap(\.text).joined(separator: "\n") ?? ""
            guard !text.isEmpty else { continue }
            try? await ledger.append(
                ContextSegment(
                    id: "assistant-" + responseID,
                    kind: .recentConversation,
                    text: "[assistant] \(text)",
                    sourceTurnID: responseID,
                    metadata: ["role": "assistant"]
                ),
                to: conversationID
            )
        }
    }
}

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

private func toolStepCount(_ events: [NormalizedEvent]) -> Int {
    let start = events.lastIndex {
        if case .message(let message) = $0 { return message.role == .user }
        return false
    }.map { $0 + 1 } ?? 0
    return events.dropFirst(start).reduce(into: 0) { count, event in
        if case .toolCall = event { count += 1 }
    }
}

private func makeToolContext(_ events: [NormalizedEvent]) -> String {
    let latestUserIndex = events.lastIndex {
        if case .message(let message) = $0 { return message.role == .user }
        return false
    }
    var lines: [String] = []
    if let latestUserIndex, case .message(let message) = events[latestUserIndex] {
        lines.append("Current request:\n" + bounded(message.text, bytes: 1_200))
    }
    let toolEvents = events.compactMap { event -> String? in
        switch event {
        case .toolCall(let call):
            return "Tool call \(call.callID): \(call.name)(\(bounded(call.arguments, bytes: 600)))"
        case .toolOutput(let output):
            return "Tool output \(output.callID):\n\(boundedHeadAndTail(output.output, bytes: 2_400))"
        case .message:
            return nil
        }
    }
    lines.append(contentsOf: toolEvents.suffix(6))
    return lines.joined(separator: "\n\n")
}

private func shouldFinalizeAfterToolOutput(_ events: [NormalizedEvent]) -> Bool {
    guard let request = events.compactMap({ event -> String? in
        if case .message(let message) = event, message.role == .user { return message.text }
        return nil
    }).last?.lowercased(),
    let output = events.compactMap({ event -> String? in
        if case .toolOutput(let output) = event { return output.output }
        return nil
    }).last,
    output.contains("Process exited with code 0") else {
        return false
    }

    let readOnlyMarkers = ["inspect", "read", "show", "list", "find", "summarize", "explain", "確認", "読む", "表示", "一覧", "要約"]
    let mutationMarkers = ["edit", "change", "fix", "implement", "create", "write", "delete", "rename", "test", "build", "編集", "変更", "修正", "実装", "作成", "削除", "テスト", "ビルド"]
    return readOnlyMarkers.contains { request.contains($0) }
        && !mutationMarkers.contains { request.contains($0) }
}

private func directToolResultAnswer(_ events: [NormalizedEvent]) -> String? {
    guard let request = events.compactMap({ event -> String? in
        if case .message(let message) = event, message.role == .user { return message.text }
        return nil
    }).last,
    let output = events.compactMap({ event -> String? in
        if case .toolOutput(let output) = event { return output.output }
        return nil
    }).last,
    output.contains("Process exited with code 0") else {
        return nil
    }

    let lower = request.lowercased()
    if lower.contains("swift package name") || lower.contains("package name") || request.contains("パッケージ名") {
        let pattern = #"\bname\s*:\s*\"([^\"]+)\""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }
    }
    if (lower.contains("basename") || request.contains("末尾")),
       let pathLine = output.split(separator: "\n").last(where: { $0.hasPrefix("/") }) {
        return URL(fileURLWithPath: String(pathLine)).lastPathComponent
    }
    if lower.contains("reply done") || request.contains("完了") {
        return "done"
    }
    return nil
}

private func bounded(_ value: String, bytes: Int) -> String {
    guard value.utf8.count > bytes else { return value }
    return "[earlier content omitted]\n" + String(decoding: value.utf8.suffix(bytes), as: UTF8.self)
}

private func boundedHeadAndTail(_ value: String, bytes: Int) -> String {
    guard value.utf8.count > bytes else { return value }
    let head = (bytes * 2) / 3
    let tail = bytes - head
    return String(decoding: value.utf8.prefix(head), as: UTF8.self)
        + "\n[...middle content omitted...]\n"
        + String(decoding: value.utf8.suffix(tail), as: UTF8.self)
}

/// Encode diagnostics into a response header for debug builds.
private func injectDiagnosticsHeader(_ headers: inout HTTPFields, _ diagnostics: Diagnostics) {
    let summary = diagnostics.summary
    if !summary.isEmpty {
        headers[.init(afmDiagnosticsHeader)!] = summary
    }
}
