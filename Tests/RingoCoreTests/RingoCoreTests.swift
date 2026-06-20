import Testing
import Foundation
import AgentBridgeCore
import Hummingbird
import HummingbirdTesting
import HTTPTypes
@testable import RingoCore

@Suite struct RingoCoreTests {
    @Test func claudeInvocationInjectsGatewayEnvironmentAndPreservesArguments() throws {
        let invocation = try RingoRuntime.invocation(
            for: .claude,
            host: "127.0.0.1",
            port: 9001,
            arguments: ["--", "--print", "hello"],
            inheritedEnvironment: [:],
            executable: "/tmp/claude"
        )
        #expect(invocation.arguments == ["--print", "hello"])
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9001/anthropic")
        #expect(invocation.environment["ANTHROPIC_MODEL"] == "claude-afm-local")
        #expect(invocation.environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "claude-afm-local")
    }

    @Test func codexInvocationPrependsProviderOverrides() throws {
        let invocation = try RingoRuntime.invocation(
            for: .codex,
            host: "127.0.0.1",
            port: 9002,
            arguments: ["--", "exec", "hello"],
            inheritedEnvironment: [:],
            executable: "/tmp/codex"
        )
        #expect(invocation.arguments.suffix(2) == ["exec", "hello"])
        #expect(invocation.arguments.contains("model_provider=\"ringo\""))
        #expect(invocation.arguments.contains("model_providers.ringo.base_url=\"http://127.0.0.1:9002/openai/v1\""))
        #expect(invocation.arguments.contains("model_context_window=4096"))
        #expect(invocation.arguments.contains("web_search=\"disabled\""))
        #expect(invocation.environment["AFM_BRIDGE_API_KEY"] == "ringo-local")
        #expect(invocation.environment["CODEX_HOME"] == RingoRuntime.defaultCodexHome)
    }

    @Test func codexCanInheritUserConfiguration() throws {
        let invocation = try RingoRuntime.invocation(
            for: .codex,
            host: "127.0.0.1",
            port: 9002,
            arguments: [],
            inheritedEnvironment: ["CODEX_HOME": "/tmp/existing-codex"],
            executable: "/tmp/codex",
            inheritCodexConfig: true
        )
        #expect(invocation.environment["CODEX_HOME"] == "/tmp/existing-codex")
    }

    @Test func codexExecSkipsGitCheckOnlyOutsideRepositories() throws {
        let nonGit = FileManager.default.temporaryDirectory
            .appendingPathComponent("ringo-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonGit) }

        let outside = try RingoRuntime.invocation(
            for: .codex,
            host: "127.0.0.1",
            port: 9002,
            arguments: ["exec", "inspect"],
            inheritedEnvironment: [:],
            executable: "/tmp/codex",
            workingDirectory: nonGit.path
        )
        #expect(outside.arguments.contains("--skip-git-repo-check"))

        let inside = try RingoRuntime.invocation(
            for: .codex,
            host: "127.0.0.1",
            port: 9002,
            arguments: ["exec", "inspect"],
            inheritedEnvironment: [:],
            executable: "/tmp/codex",
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        #expect(!inside.arguments.contains("--skip-git-repo-check"))
    }

    @Test func extractsOnlyTheFinalCodexAgentMessage() {
        let jsonLines = """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"item.completed","item":{"type":"agent_message","text":"first"}}
        {"type":"item.completed","item":{"type":"command_execution","command":"pwd"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Hello!"}}
        {"type":"turn.completed"}
        """
        #expect(RingoRuntime.finalAgentMessage(from: jsonLines) == "Hello!")
    }

    @Test func gatewayLaunchConfigurationDefaultsCanBeMadePersistent() throws {
        let config = try RingoRuntime.gatewayConfiguration(
            host: "127.0.0.1",
            port: 9000,
            contextMode: "persistent",
            environment: ["AFM_BRIDGE_CONTEXT_RETENTION_DAYS": "30"]
        )
        #expect(config.contextMode == .persistent)
        #expect(config.contextPath == nil)
        #expect(config.retentionDays == 30)
        #expect(throws: RingoError.self) {
            try RingoRuntime.gatewayConfiguration(host: "127.0.0.1", port: 9000, contextMode: "invalid")
        }
    }

    @Test func allocatesBindableEphemeralPort() throws {
        let port = try RingoRuntime.availablePort()
        #expect(port > 0)
        #expect(RingoRuntime.isPortAvailable(port))
    }

    @Test func parsesKnownAgentsAndRejectsUnknownAgent() throws {
        #expect(try RingoRuntime.agent(named: "claude") == .claude)
        #expect(try RingoRuntime.agent(named: "codex") == .codex)
        #expect(throws: RingoError.self) { try RingoRuntime.agent(named: "other") }
    }

    @Test func serveInstructionsContainExpectedIntegration() {
        let instructions = RingoRuntime.gatewayServeInstructions(
            host: "127.0.0.1", port: 8765, environment: ["AFM_BRIDGE_API_KEY": "dev-token"]
        )
        #expect(instructions.contains("/dashboard"))
        #expect(instructions.contains("ANTHROPIC_BASE_URL='http://127.0.0.1:8765/anthropic'"))
        #expect(instructions.contains("/openai/v1"))
        #expect(instructions.contains("ANTHROPIC_AUTH_TOKEN='dev-token'"))
        #expect(instructions.contains("AFM_BRIDGE_API_KEY='dev-token'"))
    }

    @Test func configuredGatewayTokenIsSharedWithClaudeAndCodexChildren() throws {
        let inherited = ["AFM_BRIDGE_API_KEY": "dev-token"]
        let claude = try RingoRuntime.invocation(
            for: .claude,
            host: "127.0.0.1",
            port: 9001,
            arguments: [],
            inheritedEnvironment: inherited,
            executable: "/tmp/claude"
        )
        let codex = try RingoRuntime.invocation(
            for: .codex,
            host: "127.0.0.1",
            port: 9002,
            arguments: [],
            inheritedEnvironment: inherited,
            executable: "/tmp/codex"
        )
        let gateway = GatewayConfiguration.fromEnvironment(
            host: "127.0.0.1", port: 9000, environment: inherited
        )

        #expect(claude.environment["ANTHROPIC_AUTH_TOKEN"] == "dev-token")
        #expect(claude.environment["ANTHROPIC_API_KEY"] == "dev-token")
        #expect(codex.environment["AFM_BRIDGE_API_KEY"] == "dev-token")
        #expect(gateway.authToken == "dev-token")
    }

    @Test func emptyGatewayTokenFallsBackConsistently() {
        let environment = ["AFM_BRIDGE_API_KEY": ""]
        #expect(RingoRuntime.gatewayToken(environment: environment) == RingoRuntime.localToken)
        #expect(GatewayConfiguration.fromEnvironment(
            host: "127.0.0.1", port: 9000, environment: environment
        ).authToken == RingoRuntime.localToken)
    }

    @Test func childExitStatusIsPreserved() async throws {
        let invocation = ChildInvocation(
            executable: "/usr/bin/false",
            arguments: [],
            environment: [:]
        )
        #expect(try await RingoRuntime.runChild(invocation) == 1)
    }

    @Test func gatewayExposesRedactedAdminStateAndProtectsMutations() async throws {
        let ledger = InMemoryContextLedger()
        await ledger.saveConversation(.init(
            id: "session-1", protocolName: "codex", fingerprint: "private-fingerprint", turnHashes: ["one"]
        ))
        await ledger.append(.init(id: "segment-1", kind: .currentRequest, text: "private prompt"), to: "session-1")
        await ledger.cacheArtifact(hash: "artifact-1", text: "private artifact", metadata: ["path": "Secret.swift"])
        let app = try await RingoGateway.buildApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "secret"), ledger: ledger
        )
        try await app.test(.router) { client in
            try await client.execute(uri: "/dashboard/state.json", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("mountedProtocols"))
                #expect(!body.contains("private prompt"))
            }
            try await client.execute(uri: "/sessions/session-1/segments", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("[redacted]"))
            }
            try await client.execute(uri: "/sessions/session-1", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
            let headers: HTTPFields = [.authorization: "Bearer secret"]
            try await client.execute(uri: "/sessions/session-1/resume", method: .post, headers: headers) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("private prompt"))
            }
        }
    }

    @Test func gatewayMountsBothProtocolSurfaces() async throws {
        let app = try await RingoGateway.buildApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "secret")
        )
        let headers: HTTPFields = [.authorization: "Bearer secret"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/openai/v1/models?client_version=0.135.0", method: .get, headers: headers
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("apple-foundation-local"))
                #expect(body.contains("context_window"))
            }
            try await client.execute(uri: "/openai/v1/responses", method: .post, headers: headers) { response in
                #expect(response.status != .notFound)
            }
            try await client.execute(uri: "/anthropic/v1/messages", method: .post, headers: headers) { response in
                #expect(response.status != .notFound)
            }
        }
    }

    @Test func nonLoopbackGatewayRequiresAuthenticationForDashboardReads() async throws {
        let app = try await RingoGateway.buildApplication(
            config: .init(host: "0.0.0.0", port: 0, authToken: "secret")
        )
        try await app.test(.router) { client in
            try await client.execute(uri: "/dashboard/state.json", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            let headers: HTTPFields = [.authorization: "Bearer secret"]
            try await client.execute(uri: "/dashboard/state.json", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
