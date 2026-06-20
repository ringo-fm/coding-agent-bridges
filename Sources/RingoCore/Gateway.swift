import AFMBackend
import AgentBridgeCore
import BridgeHTTP
import ClaudeAdapter
import CodexAdapter
import Foundation
import Hummingbird
import HTTPTypes
import Logging

public struct GatewayConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var authToken: String
    public var contextMode: ContextStorageMode
    public var contextPath: String?
    public var retentionDays: Int
    public var verbose: Bool

    public init(
        host: String = "127.0.0.1",
        port: Int = 8765,
        authToken: String = RingoRuntime.localToken,
        contextMode: ContextStorageMode = .memory,
        contextPath: String? = nil,
        retentionDays: Int = 30,
        verbose: Bool = false
    ) {
        self.host = host
        self.port = port
        self.authToken = authToken
        self.contextMode = contextMode
        self.contextPath = contextPath
        self.retentionDays = retentionDays
        self.verbose = verbose
    }

    public static func fromEnvironment(
        host: String,
        port: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        return .init(
            host: host,
            port: port,
            authToken: RingoRuntime.gatewayToken(environment: environment),
            contextMode: ContextStorageMode(environmentValue: environment["AFM_BRIDGE_CONTEXT_MODE"]),
            contextPath: environment["AFM_BRIDGE_CONTEXT_PATH"],
            retentionDays: Int(environment["AFM_BRIDGE_CONTEXT_RETENTION_DAYS"] ?? "30") ?? 30,
            verbose: false
        )
    }
}

public struct GatewayFailure: Codable, Sendable, Equatable {
    public let requestID: String
    public let path: String
    public let status: Int
    public let occurredAt: Date
}

public struct GatewayTelemetrySnapshot: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let uptimeSeconds: Double
    public let totalRequests: Int
    public let activeRequests: Int
    public let failedRequests: Int
    public let averageLatencyMilliseconds: Double
    public let streamingCompletions: Int
    public let activeStreams: Int
    public let recentFailures: [GatewayFailure]
}

public actor GatewayTelemetry {
    private let startedAt = Date()
    private var totalRequests = 0
    private var activeRequests = 0
    private var failedRequests = 0
    private var totalLatencyMilliseconds = 0.0
    private var streamingCompletions = 0
    private var activeStreams = 0
    private var recentFailures: [GatewayFailure] = []

    public init() {}

    func begin() { totalRequests += 1; activeRequests += 1 }
    func beginStream() { activeStreams += 1 }
    func endStream() { activeStreams = max(0, activeStreams - 1) }
    func finish(path: String, status: Int, latency: Duration, streaming: Bool) {
        activeRequests = max(0, activeRequests - 1)
        totalLatencyMilliseconds += Double(latency.components.seconds) * 1_000
            + Double(latency.components.attoseconds) / 1_000_000_000_000_000
        if streaming { streamingCompletions += 1 }
        if status >= 400 {
            failedRequests += 1
            recentFailures.insert(.init(
                requestID: UUID().uuidString.lowercased(), path: path, status: status, occurredAt: Date()
            ), at: 0)
            recentFailures = Array(recentFailures.prefix(20))
        }
    }
    func fail(path: String, latency: Duration) {
        finish(path: path, status: 500, latency: latency, streaming: false)
    }
    public func snapshot() -> GatewayTelemetrySnapshot {
        .init(
            startedAt: startedAt,
            uptimeSeconds: Date().timeIntervalSince(startedAt),
            totalRequests: totalRequests,
            activeRequests: activeRequests,
            failedRequests: failedRequests,
            averageLatencyMilliseconds: totalRequests == 0 ? 0 : totalLatencyMilliseconds / Double(totalRequests),
            streamingCompletions: streamingCompletions,
            activeStreams: activeStreams,
            recentFailures: recentFailures
        )
    }
}

public struct GatewayState: Codable, Sendable {
    public let status: String
    public let modelAvailable: Bool
    public let model: String
    public let mountedProtocols: [String]
    public let host: String
    public let port: Int
    public let authEnabled: Bool
    public let storage: ContextStorageStatus
    public let sessions: [SessionSummary]
    public let cache: ContextCacheStats
    public let telemetry: GatewayTelemetrySnapshot
}

struct GatewayMiddleware: RouterMiddleware {
    let config: GatewayConfiguration
    let telemetry: GatewayTelemetry

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        let path = request.uri.path
        let isRead = request.method == .get || request.method == .head
        let isAdmin = path == "/dashboard" || path.hasPrefix("/dashboard/")
            || path == "/sessions" || path.hasPrefix("/sessions/")
            || path == "/cache" || path.hasPrefix("/cache/")
        let contentRequested = request.uri.queryParameters["include_content"] == "true"
        let hostIsLoopback = ["127.0.0.1", "localhost", "::1"].contains(config.host)
        let mayReadWithoutAuth = isAdmin && isRead && hostIsLoopback && !contentRequested
        let bypass = path == "/health" || mayReadWithoutAuth
        let shouldTrack = !isAdmin && path != "/health" && path != "/favicon.ico"
        let clock = ContinuousClock()
        let started = clock.now
        if shouldTrack { await telemetry.begin() }
        if !bypass && !BridgeAuthorization.matches(headers: request.headers, expectedToken: config.authToken) {
            if shouldTrack {
                await telemetry.finish(
                    path: path, status: 401, latency: started.duration(to: clock.now), streaming: false
                )
            }
            return jsonResponse(["error": "unauthorized"], status: .unauthorized)
        }

        do {
            var response = try await next(request, context)
            let streaming = response.headers[.contentType]?.contains("text/event-stream") == true
            if shouldTrack && streaming {
                await telemetry.beginStream()
                let originalBody = response.body
                response.body = ResponseBody(contentLength: originalBody.contentLength) { writer in
                    do {
                        try await originalBody.write(writer)
                        await telemetry.endStream()
                    } catch {
                        await telemetry.endStream()
                        throw error
                    }
                }
            }
            if shouldTrack {
                await telemetry.finish(
                    path: path,
                    status: response.status.code,
                    latency: started.duration(to: clock.now),
                    streaming: streaming
                )
            }
            return response
        } catch {
            if shouldTrack { await telemetry.fail(path: path, latency: started.duration(to: clock.now)) }
            throw error
        }
    }
}

public enum RingoGateway {
    public static func buildApplication(
        config: GatewayConfiguration,
        telemetry: GatewayTelemetry = GatewayTelemetry(),
        ledger suppliedLedger: (any ContextLedger)? = nil
    ) async throws -> some ApplicationProtocol {
        var logger = Logger(label: "ringo-gateway")
        logger.logLevel = config.verbose ? .info : .critical
        var serverLogger = Logger(label: "ringo-gateway-server")
        // Hummingbird reports normal task cancellation during launcher teardown
        // as errors ("Already closed" / CancellationError). Startup failures
        // still propagate from runService; keep routine server lifecycle noise
        // out of the user-facing coding-agent session.
        serverLogger.logLevel = .critical
        let ledger = try suppliedLedger ?? ContextLedgerFactory.make(
            mode: config.contextMode,
            path: config.contextPath,
            retentionDays: config.retentionDays
        )
        try await ledger.purgeExpired()
        let backend = FoundationModelsBackend()

        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: GatewayMiddleware(config: config, telemetry: telemetry))

        mountCodexRoutes(
            on: router.group(), host: config.host, port: config.port, authToken: config.authToken,
            sharedBackend: backend, contextLedger: ledger, logger: logger
        )
        mountCodexRoutes(
            on: router.group("openai"), host: config.host, port: config.port, authToken: config.authToken,
            sharedBackend: backend, contextLedger: ledger, logger: logger, includeSharedRoutes: true
        )
        mountClaudeRoutes(
            on: router.group("anthropic"),
            host: config.host,
            port: config.port,
            authToken: config.authToken,
            sharedBackend: backend,
            contextLedger: ledger
        )

        mountManagementRoutes(
            on: router.group(), config: config, backend: backend, ledger: ledger, telemetry: telemetry
        )

        return Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "ringo-gateway"
            ),
            logger: serverLogger
        )
    }

    public static func run(config: GatewayConfiguration) async throws {
        let app = try await buildApplication(config: config)
        try await app.runService()
    }
}

private func mountManagementRoutes(
    on router: RouterGroup<BasicRequestContext>,
    config: GatewayConfiguration,
    backend: FoundationModelsBackend,
    ledger: any ContextLedger,
    telemetry: GatewayTelemetry
) {
    router.get("health") { _, _ in
        let state = await makeState(config: config, backend: backend, ledger: ledger, telemetry: telemetry)
        return jsonResponse(["status": state.status, "protocols": "openai,anthropic"])
    }
    router.get("favicon.ico") { _, _ in Response(status: .noContent) }
    router.get("v1/models") { _, _ in
        jsonResponse(GatewayModelsResponse(
            object: "list",
            data: [.init(id: CodexAdapter.defaultModel, object: "model")]
        ))
    }
    router.get("dashboard") { _, _ in htmlResponse(dashboardHTML) }
    router.get("dashboard/state.json") { _, _ in
        jsonResponse(await makeState(config: config, backend: backend, ledger: ledger, telemetry: telemetry))
    }

    router.get("sessions") { request, _ in
        let limit = request.uri.queryParameters["limit"].flatMap { Int($0) } ?? 100
        return try await jsonResponse(ledger.listConversations(limit: min(max(limit, 0), 500)))
    }
    router.get("sessions/:id") { _, context in
        guard let id = context.parameters.get("id", as: String.self),
              let conversation = try await ledger.conversation(id: id) else { return notFound() }
        let summaries = try await ledger.listConversations(limit: 500)
        guard let summary = summaries.first(where: { $0.id == id }) else { return notFound() }
        return jsonResponse(SessionDetail(summary: summary, fingerprint: conversation.fingerprint, turnHashes: conversation.turnHashes))
    }
    router.get("sessions/:id/segments") { request, context in
        guard let id = context.parameters.get("id", as: String.self) else { return notFound() }
        let include = request.uri.queryParameters["include_content"] == "true"
        let segments = try await ledger.segments(for: id, limit: 500)
        return jsonResponse(include ? segments : segments.map(redactedSegment))
    }
    router.get("sessions/:id/capsule") { request, context in
        guard let id = context.parameters.get("id", as: String.self),
              let capsule = try await ledger.capsule(for: id) else { return notFound() }
        let include = request.uri.queryParameters["include_content"] == "true"
        return jsonResponse(include ? capsule : redactedCapsule(capsule))
    }
    router.get("sessions/:id/export") { request, context in
        guard let id = context.parameters.get("id", as: String.self),
              let conversation = try await ledger.conversation(id: id) else { return notFound() }
        let include = request.uri.queryParameters["include_content"] == "true"
        let segments = try await ledger.segments(for: id, limit: 10_000)
        let capsule = try await ledger.capsule(for: id)
        return jsonResponse(SessionExport(
            conversation: conversation,
            segments: include ? segments : segments.map(redactedSegment),
            capsule: include ? capsule : capsule.map(redactedCapsule),
            includesContent: include
        ), sortedKeys: true)
    }
    router.post("sessions/:id/resume") { _, context in
        guard let id = context.parameters.get("id", as: String.self),
              let conversation = try await ledger.conversation(id: id) else { return notFound() }
        return try await jsonResponse(SessionResumeBundle(
            conversation: conversation,
            recentSegments: ledger.segments(for: id, limit: 50),
            capsule: ledger.capsule(for: id)
        ))
    }
    router.delete("sessions/:id") { _, context in
        guard let id = context.parameters.get("id", as: String.self) else { return notFound() }
        try await ledger.deleteConversation(id: id)
        return jsonResponse(["deleted": id])
    }
    router.post("sessions/prune") { _, _ in
        try await ledger.purgeExpired()
        return jsonResponse(["status": "pruned"])
    }

    router.get("cache/stats") { _, _ in try await jsonResponse(ledger.cacheStats()) }
    router.get("cache/search") { request, _ in
        let query = String(request.uri.queryParameters["q"] ?? "")
        let include = request.uri.queryParameters["include_content"] == "true"
        let values = try await ledger.searchArtifacts(query: query, limit: 50)
        return jsonResponse(include ? values : values.map(redactedArtifact))
    }
    router.get("cache/artifacts/:hash") { request, context in
        guard let hash = context.parameters.get("hash", as: String.self),
              let artifact = try await ledger.artifact(hash: hash) else { return notFound() }
        return jsonResponse(request.uri.queryParameters["include_content"] == "true" ? artifact : redactedArtifact(artifact))
    }
    router.post("cache/prune") { request, _ in
        let days = request.uri.queryParameters["days"].flatMap { Int($0) } ?? config.retentionDays
        try await ledger.pruneArtifacts(olderThan: Date().addingTimeInterval(-Double(max(1, days)) * 86_400))
        return jsonResponse(["status": "pruned"])
    }
    router.delete("cache/artifacts") { _, _ in
        try await ledger.clearArtifactCache()
        return jsonResponse(["status": "cleared"])
    }
}

private func makeState(
    config: GatewayConfiguration,
    backend: FoundationModelsBackend,
    ledger: any ContextLedger,
    telemetry: GatewayTelemetry
) async -> GatewayState {
    let available: Bool
    if case .available = backend.status() { available = true } else { available = false }
    return GatewayState(
        status: available ? "ok" : "unavailable",
        modelAvailable: available,
        model: CodexAdapter.defaultModel,
        mountedProtocols: ["openai", "anthropic"],
        host: config.host,
        port: config.port,
        authEnabled: !config.authToken.isEmpty,
        storage: await ledger.storageStatus(),
        sessions: (try? await ledger.listConversations(limit: 10)) ?? [],
        cache: (try? await ledger.cacheStats()) ?? .init(enabled: false, artifactCount: 0),
        telemetry: await telemetry.snapshot()
    )
}

private func redactedSegment(_ segment: ContextSegment) -> ContextSegment {
    ContextSegment(
        id: segment.id,
        kind: segment.kind,
        text: "[redacted]",
        sourceTurnID: segment.sourceTurnID,
        metadata: segment.metadata.mapValues { _ in "[redacted]" }
    )
}

private func redactedCapsule(_ capsule: ContextCapsule) -> ContextCapsule {
    ContextCapsule(
        objective: capsule.objective.isEmpty ? "" : "[redacted]",
        constraints: capsule.constraints.map { _ in "[redacted]" },
        decisions: capsule.decisions.map { _ in "[redacted]" },
        filesAndSymbols: capsule.filesAndSymbols.map { _ in "[redacted]" },
        completedActions: capsule.completedActions.map { _ in "[redacted]" },
        failedAttempts: capsule.failedAttempts.map { _ in "[redacted]" },
        pendingTasks: capsule.pendingTasks.map { _ in "[redacted]" },
        sourceTurnIDs: capsule.sourceTurnIDs
    )
}

private struct GatewayModelsResponse: Encodable {
    struct Model: Encodable { let id: String; let object: String }
    let object: String
    let data: [Model]
}

private func redactedArtifact(_ artifact: RetrievedArtifact) -> RetrievedArtifact {
    RetrievedArtifact(
        hash: artifact.hash,
        text: "[redacted]",
        metadata: Dictionary(uniqueKeysWithValues: artifact.metadata.keys.sorted().map { ($0, "[redacted]") }),
        score: artifact.score
    )
}

private func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok,
    sortedKeys: Bool = false
) -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if sortedKeys { encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] }
    let data = (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding_failed\"}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
}

private func htmlResponse(_ html: String) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "text/html; charset=utf-8"
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(string: html)))
}

private func notFound() -> Response { jsonResponse(["error": "not_found"], status: .notFound) }

private let dashboardHTML = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ringo Bridge</title><style>
:root{color-scheme:dark;--bg:#050a11;--surface:#0c1522;--line:#263344;--text:#edf4ff;--muted:#94a7c2;--green:#67d67d;--amber:#f0b429;--red:#ff6b6b}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;overflow-x:hidden}header{display:flex;align-items:center;justify-content:space-between;padding:24px 28px;border-bottom:1px solid var(--line)}h1{font-size:25px;margin:0;letter-spacing:.02em}.status{color:var(--green)}main{padding:22px 28px 32px;max-width:1500px;margin:auto}.rail{display:grid;grid-template-columns:repeat(6,1fr);border:1px solid var(--line);background:var(--surface)}.metric{padding:16px 18px;border-right:1px solid var(--line)}.metric:last-child{border:0}.label,.panel h2,th{color:var(--muted);text-transform:uppercase;letter-spacing:.08em;font-size:12px}.value{display:block;font-size:24px;margin-top:4px}.layout{display:grid;grid-template-columns:1.3fr 1fr;gap:18px;margin-top:18px}.panel{border:1px solid var(--line);background:var(--surface);min-width:0;overflow-x:auto}.panel h2{margin:0;padding:14px 16px;border-bottom:1px solid var(--line)}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:12px 16px;border-bottom:1px solid var(--line)}tr:last-child td{border:0}.empty{color:var(--muted);padding:24px 16px}.wide{grid-column:1/-1}footer{padding-top:18px;color:var(--muted);display:flex;justify-content:space-between}@media(max-width:900px){.rail{grid-template-columns:repeat(2,1fr)}.metric{border-bottom:1px solid var(--line)}.layout{grid-template-columns:1fr}header{align-items:flex-start;gap:8px;flex-direction:column}main{padding:16px}.wide{grid-column:auto}.panel table{table-layout:fixed}.panel th,.panel td{padding:10px 8px;font-size:12px;overflow-wrap:anywhere}}
</style></head><body><header><h1>Ringo Bridge</h1><div id="health" class="status">● Loading</div></header><main>
<section class="rail"><div class="metric"><span class="label">Uptime</span><span class="value" id="uptime">—</span></div><div class="metric"><span class="label">Requests</span><span class="value" id="requests">0</span></div><div class="metric"><span class="label">Active</span><span class="value" id="active">0</span></div><div class="metric"><span class="label">Failed</span><span class="value" id="failed">0</span></div><div class="metric"><span class="label">Avg latency</span><span class="value" id="latency">0 ms</span></div><div class="metric"><span class="label">Streams</span><span class="value" id="streams">0</span></div></section>
<div class="layout"><section class="panel wide"><h2>Mounted endpoints</h2><table><thead><tr><th>Protocol</th><th>Base path</th><th>Status</th></tr></thead><tbody><tr><td>OpenAI / Codex</td><td>/openai/v1</td><td class="status">Healthy</td></tr><tr><td>Anthropic / Claude</td><td>/anthropic/v1</td><td class="status">Healthy</td></tr></tbody></table></section>
<section class="panel"><h2>Sessions</h2><table><tbody id="sessions"><tr><td class="empty">No sessions</td></tr></tbody></table></section><section class="panel"><h2>Cache</h2><table><tbody><tr><td>Storage mode</td><td id="storage">—</td></tr><tr><td>Artifacts</td><td id="artifacts">0</td></tr><tr><td>Estimated bytes</td><td id="bytes">0</td></tr></tbody></table></section>
<section class="panel wide"><h2>Recent failures</h2><table><thead><tr><th>Time</th><th>Request ID</th><th>Path</th><th>Status</th></tr></thead><tbody id="failures"><tr><td colspan="4" class="empty">No recent failures</td></tr></tbody></table></section></div><footer><span id="address">localhost</span><span>Auto refresh · 2s</span></footer></main>
<script>const e=id=>document.getElementById(id),esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));async function refresh(){try{const s=await fetch('/dashboard/state.json').then(r=>r.json()),t=s.telemetry;e('health').textContent='● '+(s.status==='ok'?'Healthy':'Unavailable');e('uptime').textContent=Math.floor(t.uptimeSeconds/60)+'m '+Math.floor(t.uptimeSeconds%60)+'s';e('requests').textContent=t.totalRequests;e('active').textContent=t.activeRequests;e('failed').textContent=t.failedRequests;e('latency').textContent=t.averageLatencyMilliseconds.toFixed(0)+' ms';e('streams').textContent=t.streamingCompletions;e('storage').textContent=s.storage.mode;e('artifacts').textContent=s.cache.artifactCount;e('bytes').textContent=s.cache.estimatedBytes??'—';e('address').textContent=s.host+':'+s.port;e('sessions').innerHTML=s.sessions.length?s.sessions.map(x=>`<tr><td>${esc(x.protocolName)}</td><td>${esc(x.id)}</td><td>${x.turnCount} turns</td></tr>`).join(''):'<tr><td class="empty">No sessions</td></tr>';e('failures').innerHTML=t.recentFailures.length?t.recentFailures.map(x=>`<tr><td>${new Date(x.occurredAt).toLocaleTimeString()}</td><td>${esc(x.requestID.slice(0,8))}</td><td>${esc(x.path)}</td><td>${x.status}</td></tr>`).join(''):'<tr><td colspan="4" class="empty">No recent failures</td></tr>'}catch{e('health').textContent='● Disconnected'}}refresh();setInterval(refresh,2000)</script></body></html>
"""#
