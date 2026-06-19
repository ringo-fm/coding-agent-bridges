import Foundation
import Logging
import AgentBridgeCore

public struct BridgeConfig: Sendable {
    public let host: String
    public let port: Int
    public let authToken: String?
    public let logLevel: Logger.Level
    public let debug: Bool
    public let contextMode: ContextStorageMode
    public let contextPath: String?
    public let contextRetentionDays: Int

    public var requiresAuth: Bool { authToken != nil }

    public init(
        host: String,
        port: Int,
        authToken: String?,
        logLevel: Logger.Level,
        debug: Bool,
        contextMode: ContextStorageMode = .memory,
        contextPath: String? = nil,
        contextRetentionDays: Int = 30
    ) {
        self.host = host
        self.port = port
        self.authToken = authToken
        self.logLevel = logLevel
        self.debug = debug
        self.contextMode = contextMode
        self.contextPath = contextPath
        self.contextRetentionDays = contextRetentionDays
    }

    public static func resolve(
        host: String?,
        port: Int?,
        authToken: String?,
        logLevel: String?,
        debug: Bool,
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> BridgeConfig {
        let resolvedHost = host ?? env["AFM_BRIDGE_HOST"] ?? "127.0.0.1"
        let resolvedPort = port ?? env["AFM_BRIDGE_PORT"].flatMap(Int.init) ?? 8766
        let token = authToken ?? env["AFM_BRIDGE_API_KEY"] ?? env["ANTHROPIC_AUTH_TOKEN"]
        let levelString = logLevel ?? env["AFM_BRIDGE_LOG_LEVEL"] ?? "info"
        let level = Logger.Level(rawValue: levelString) ?? .info
        let dbg = debug || (env["AFM_BRIDGE_DEBUG"] == "1")
        return BridgeConfig(
            host: resolvedHost,
            port: resolvedPort,
            authToken: token,
            logLevel: level,
            debug: dbg,
            contextMode: ContextStorageMode(environmentValue: env["AFM_BRIDGE_CONTEXT_MODE"]),
            contextPath: env["AFM_BRIDGE_CONTEXT_PATH"],
            contextRetentionDays: Int(env["AFM_BRIDGE_CONTEXT_RETENTION_DAYS"] ?? "30") ?? 30
        )
    }
}
