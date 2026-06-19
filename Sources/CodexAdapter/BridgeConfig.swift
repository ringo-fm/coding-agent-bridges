import Foundation
import Logging
import AgentBridgeCore

/// Environment-driven configuration for the bridge.
public struct BridgeConfig: Sendable {
    public var host: String
    public var port: Int
    public var authToken: String
    public var logLevel: Logger.Level
    public var debug: Bool
    public var contextMode: ContextStorageMode
    public var contextPath: String?
    public var contextRetentionDays: Int

    public init(
        host: String,
        port: Int,
        authToken: String,
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

    /// Load configuration from environment variables.
    ///
    /// - `AFM_BRIDGE_HOST` (default `127.0.0.1`)
    /// - `AFM_BRIDGE_PORT` (default `8765`)
    /// - `AFM_BRIDGE_API_KEY` (required; falls back to `AFM_BRIDGE_TOKEN`)
    /// - `AFM_BRIDGE_LOG_LEVEL` (default `info`)
    /// - `AFM_BRIDGE_DEBUG` (default `false`)
    public static func load() throws -> BridgeConfig {
        let env = ProcessInfo.processInfo.environment

        let host = env["AFM_BRIDGE_HOST"] ?? "127.0.0.1"
        let port = Int(env["AFM_BRIDGE_PORT"] ?? "8765") ?? 8765

        let authToken = env["AFM_BRIDGE_API_KEY"] ?? env["AFM_BRIDGE_TOKEN"]
        guard let authToken, !authToken.isEmpty else {
            throw BridgeError.invalidRequest(
                "AFM_BRIDGE_API_KEY environment variable is required to start the bridge."
            )
        }

        let levelRaw = (env["AFM_BRIDGE_LOG_LEVEL"] ?? "info").lowercased()
        let logLevel: Logger.Level
        switch levelRaw {
        case "trace": logLevel = .trace
        case "debug": logLevel = .debug
        case "info": logLevel = .info
        case "notice", "warning": logLevel = .notice
        case "error": logLevel = .error
        default: logLevel = .info
        }

        let debug = (env["AFM_BRIDGE_DEBUG"] ?? "0").lowercased() == "1"
            || (env["AFM_BRIDGE_DEBUG"] ?? "false").lowercased() == "true"
        let contextMode = ContextStorageMode(environmentValue: env["AFM_BRIDGE_CONTEXT_MODE"])
        let contextPath = env["AFM_BRIDGE_CONTEXT_PATH"]
        let retentionDays = Int(env["AFM_BRIDGE_CONTEXT_RETENTION_DAYS"] ?? "30") ?? 30

        return BridgeConfig(
            host: host,
            port: port,
            authToken: authToken,
            logLevel: logLevel,
            debug: debug,
            contextMode: contextMode,
            contextPath: contextPath,
            contextRetentionDays: retentionDays
        )
    }
}
