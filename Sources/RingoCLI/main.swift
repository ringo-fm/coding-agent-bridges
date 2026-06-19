import ArgumentParser
import Darwin
import Foundation
import RingoCore

@main
struct Ringo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ringo",
        abstract: "Run coding agents against Apple Foundation Models.",
        subcommands: [Claude.self, Codex.self, Run.self, Serve.self, Doctor.self]
    )

    struct Claude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch Claude Code through the local bridge.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws { try await launch(.claude, arguments: arguments) }
    }

    struct Codex: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch Codex through the local bridge.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws { try await launch(.codex, arguments: arguments) }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Explicitly launch an agent through its bridge.")
        @Argument var agent: String
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws { try await launch(RingoRuntime.agent(named: agent), arguments: arguments) }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a bridge for an external integration.")
        @Argument var agent: String
        @Option var host = "127.0.0.1"
        @Option var port: Int?

        func run() async throws {
            let selected = try RingoRuntime.agent(named: agent)
            let selectedPort = port ?? selected.defaultPort
            let server = Task { try await RingoRuntime.runBridge(agent: selected, host: host, port: selectedPort) }
            do {
                try await RingoRuntime.waitUntilHealthy(host: host, port: selectedPort)
                print(RingoRuntime.serveInstructions(agent: selected, host: host, port: selectedPort))
                try await server.value
            } catch {
                server.cancel()
                throw error
            }
        }
    }

    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check local readiness.")
        func run() throws {
            let checks = RingoDoctor.checks()
            for check in checks {
                print("\(check.passed ? "PASS" : "FAIL")  \(check.name): \(check.detail)")
            }
            if checks.contains(where: { !$0.passed }) { throw ExitCode.failure }
        }
    }
}

private func launch(_ agent: RingoAgent, arguments: [String]) async throws {
    let port = try RingoRuntime.availablePort()
    let invocation = try RingoRuntime.invocation(
        for: agent, host: "127.0.0.1", port: port, arguments: arguments
    )
    let server = Task { try await RingoRuntime.runBridge(agent: agent, host: "127.0.0.1", port: port) }
    do {
        try await RingoRuntime.waitUntilHealthy(host: "127.0.0.1", port: port)
        let status = try await RingoRuntime.runChild(invocation)
        server.cancel()
        if status != 0 { throw ExitCode(status) }
    } catch {
        server.cancel()
        throw error
    }
}
