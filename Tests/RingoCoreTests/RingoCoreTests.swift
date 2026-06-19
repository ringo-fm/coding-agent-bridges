import Testing
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
        #expect(invocation.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9001")
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
        #expect(invocation.arguments.contains("model_providers.ringo.base_url=\"http://127.0.0.1:9002/v1\""))
        #expect(invocation.environment["AFM_BRIDGE_API_KEY"] == "ringo-local")
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
        let claude = RingoRuntime.serveInstructions(agent: .claude, host: "127.0.0.1", port: 8766)
        #expect(claude.contains("export ANTHROPIC_BASE_URL='http://127.0.0.1:8766'"))
        let codex = RingoRuntime.serveInstructions(agent: .codex, host: "127.0.0.1", port: 8765)
        #expect(codex.contains("export AFM_BRIDGE_API_KEY='ringo-local'"))
        #expect(codex.contains("model_provider=\"ringo\""))
    }

    @Test func childExitStatusIsPreserved() async throws {
        let invocation = ChildInvocation(
            executable: "/usr/bin/false",
            arguments: [],
            environment: [:]
        )
        #expect(try await RingoRuntime.runChild(invocation) == 1)
    }
}
