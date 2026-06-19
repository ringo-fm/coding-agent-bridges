import Foundation
import FoundationModels
import AgentBridgeCore
import AFMBackend
import Hummingbird
import Logging
import NIOCore

public func buildApplication(config: BridgeConfig) async throws -> some ApplicationProtocol {
    var logger = Logger(label: "claude-afm-bridge")
    logger.logLevel = config.logLevel
    let afm = AFMRuntime()
    let diagnostics = Diagnostics(logger: logger, debug: config.debug)
    let contextLedger = try ContextLedgerFactory.make(
        mode: config.contextMode,
        path: config.contextPath,
        retentionDays: config.contextRetentionDays
    )
    try await contextLedger.purgeExpired()

    if afm.availability.isAvailable {
        logger.info("Apple Foundation Models available; bridge listening on \(config.host):\(config.port)")
    } else {
        logger.warning("Apple Foundation Models unavailable; /v1/messages will return afm_unavailable until the model is ready.")
    }

    let router = buildRouter(config: config, afm: afm, diagnostics: diagnostics, contextLedger: contextLedger)
    let app = Application(
        router: router,
        configuration: .init(address: .hostname(config.host, port: config.port), serverName: "claude-afm-bridge"),
        logger: logger
    )
    return app
}

/// Run a configured Claude-compatible bridge until the task is cancelled.
public func runClaudeBridge(config: BridgeConfig) async throws {
    let app = try await buildApplication(config: config)
    try await app.runService()
}

/// Convenience entry point for launchers that do not need adapter-specific configuration.
public func runClaudeBridge(host: String, port: Int, authToken: String) async throws {
    try await runClaudeBridge(config: BridgeConfig(
        host: host,
        port: port,
        authToken: authToken,
        logLevel: .warning,
        debug: false
    ))
}

func buildRouter(
    config: BridgeConfig,
    afm: AFMRuntime,
    diagnostics: Diagnostics,
    contextLedger: any ContextLedger = InMemoryContextLedger()
) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)
    router.addMiddleware {
        LogRequestsMiddleware(config.logLevel)
        AuthMiddleware(config: config)
    }

    mountClaudeRoutes(
        on: router.group(),
        config: config,
        afm: afm,
        diagnostics: diagnostics,
        contextLedger: contextLedger,
        includeSharedRoutes: true
    )
    return router
}

public func mountClaudeRoutes(
    on router: RouterGroup<BasicRequestContext>,
    config: BridgeConfig,
    sharedBackend: FoundationModelsBackend,
    contextLedger: any ContextLedger,
    includeSharedRoutes: Bool = false
) {
    var logger = Logger(label: "claude-afm-bridge")
    logger.logLevel = config.logLevel
    mountClaudeRoutes(
        on: router,
        config: config,
        afm: AFMRuntime(sharedBackend: sharedBackend),
        diagnostics: Diagnostics(logger: logger, debug: config.debug),
        contextLedger: contextLedger,
        includeSharedRoutes: includeSharedRoutes
    )
}

public func mountClaudeRoutes(
    on router: RouterGroup<BasicRequestContext>,
    host: String,
    port: Int,
    authToken: String,
    sharedBackend: FoundationModelsBackend,
    contextLedger: any ContextLedger
) {
    mountClaudeRoutes(
        on: router,
        config: BridgeConfig(
            host: host,
            port: port,
            authToken: authToken,
            logLevel: .warning,
            debug: false,
            contextMode: .memory
        ),
        sharedBackend: sharedBackend,
        contextLedger: contextLedger
    )
}

private func mountClaudeRoutes(
    on router: RouterGroup<BasicRequestContext>,
    config: BridgeConfig,
    afm: AFMRuntime,
    diagnostics: Diagnostics,
    contextLedger: any ContextLedger,
    includeSharedRoutes: Bool
) {
    if includeSharedRoutes {
        router.get("health") { _, _ -> Response in
        jsonResponse(HealthResponse(status: "ok", service: "claude-afm-bridge", afmAvailable: afm.availability.isAvailable))
        }

        router.get("v1/models") { _, _ -> Response in
            jsonResponse(ModelsResponse.make())
        }
    }

    router.post("v1/messages") { request, context -> Response in
        try await handleMessages(
            request: request,
            context: context,
            afm: afm,
            diagnostics: diagnostics,
            contextLedger: contextLedger
        )
    }

    router.post("v1/messages/count_tokens") { request, context -> Response in
        try await handleCountTokens(request: request, context: context, afm: afm, diagnostics: diagnostics)
    }

}
