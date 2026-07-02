import ArgumentParser
import Darwin
import Foundation
import RingoCore

@main
struct Ringo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ringo",
        abstract: "Run coding agents against Apple Foundation Models.",
        subcommands: [Claude.self, Codex.self, Run.self, Serve.self, Doctor.self, Sessions.self, Cache.self]
    )

    struct Claude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch Claude Code through the local bridge.")
        @Option(help: "Bridge context storage: persistent, memory, or off.")
        var contextMode = "persistent"
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws { try await launch(.claude, arguments: arguments, contextMode: contextMode) }
    }

    struct Codex: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch Codex through the local bridge.")
        @Flag(help: "Use the normal Codex home and user configuration instead of the AFM-specific home.")
        var inheritUserConfig = false
        @Flag(help: "Use an isolated AFM-specific Codex home without user plugins or MCP configuration.")
        var isolatedConfig = false
        @Option(help: "Bridge context storage: persistent, memory, or off.")
        var contextMode = "persistent"
        @Flag(help: "Show Codex JSON-independent diagnostics and gateway logs.")
        var verbose = false
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws {
            try await launch(
                .codex,
                arguments: arguments,
                inheritCodexConfig: inheritUserConfig || !isolatedConfig,
                contextMode: contextMode,
                verbose: verbose
            )
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Explicitly launch an agent through its bridge.")
        @Argument var agent: String
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() async throws { try await launch(RingoRuntime.agent(named: agent), arguments: arguments) }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the unified OpenAI and Anthropic gateway.")
        @Option var host = "127.0.0.1"
        @Option var port = 8765

        func run() async throws {
            let server = Task { try await RingoRuntime.runGateway(host: host, port: port) }
            do {
                try await RingoRuntime.waitUntilHealthy(host: host, port: port)
                print(RingoRuntime.gatewayServeInstructions(host: host, port: port))
                try await server.value
            } catch {
                server.cancel()
                throw error
            }
        }
    }

    struct Sessions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect and manage gateway sessions.",
            subcommands: [List.self, Show.self, Resume.self, Export.self, Delete.self, Prune.self]
        )
        struct List: AsyncParsableCommand {
            @Option var url = "http://127.0.0.1:8765"
            @Option var limit = 100
            func run() async throws { print(try await client(url).request(path: "/sessions?limit=\(limit)")) }
        }
        struct Show: AsyncParsableCommand {
            @Argument var id: String; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/sessions/\(escaped(id))")) }
        }
        struct Resume: AsyncParsableCommand {
            @Argument var id: String; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/sessions/\(escaped(id))/resume", method: "POST")) }
        }
        struct Export: AsyncParsableCommand {
            @Argument var id: String; @Flag var includeContent = false; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/sessions/\(escaped(id))/export?include_content=\(includeContent)")) }
        }
        struct Delete: AsyncParsableCommand {
            @Argument var id: String; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/sessions/\(escaped(id))", method: "DELETE")) }
        }
        struct Prune: AsyncParsableCommand {
            @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/sessions/prune", method: "POST")) }
        }
    }

    struct Cache: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect and manage the context artifact cache.",
            subcommands: [Stats.self, Search.self, Show.self, Prune.self, Clear.self]
        )
        struct Stats: AsyncParsableCommand {
            @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/cache/stats")) }
        }
        struct Search: AsyncParsableCommand {
            @Argument var query: String; @Flag var includeContent = false; @Option var url = "http://127.0.0.1:8765"
            func run() async throws {
                let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                print(try await client(url).request(path: "/cache/search?q=\(q)&include_content=\(includeContent)"))
            }
        }
        struct Show: AsyncParsableCommand {
            @Argument var hash: String; @Flag var includeContent = false; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/cache/artifacts/\(escaped(hash))?include_content=\(includeContent)")) }
        }
        struct Prune: AsyncParsableCommand {
            @Option var days = 30; @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/cache/prune?days=\(days)", method: "POST")) }
        }
        struct Clear: AsyncParsableCommand {
            @Option var url = "http://127.0.0.1:8765"
            func run() async throws { print(try await client(url).request(path: "/cache/artifacts", method: "DELETE")) }
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

private func launch(
    _ agent: RingoAgent,
    arguments: [String],
    inheritCodexConfig: Bool = false,
    contextMode: String? = nil,
    verbose: Bool = false
) async throws {
    let port = try RingoRuntime.availablePort()
    if agent == .codex && !inheritCodexConfig {
        try RingoRuntime.prepareCodexHome()
    }
    let invocation = try RingoRuntime.invocation(
        for: agent,
        host: "127.0.0.1",
        port: port,
        arguments: arguments,
        inheritCodexConfig: inheritCodexConfig
    )
    var config = try RingoRuntime.gatewayConfiguration(
        host: "127.0.0.1",
        port: port,
        contextMode: contextMode ?? "persistent",
        verbose: verbose
    )
    // Loopback child process: accept any bearer token so agents using OAuth tokens work
    config.requiresAuth = false
    let server = Task { try await RingoRuntime.runGateway(config: config) }
    let status: Int32
    do {
        try await RingoRuntime.waitUntilHealthy(host: "127.0.0.1", port: port)
        let isCleanExec = agent == .codex
            && arguments.contains("exec")
            && !arguments.contains("--json")
            && !verbose
        status = try await (isCleanExec
            ? RingoRuntime.runCodexExecClean(invocation)
            : RingoRuntime.runChild(invocation))
    } catch {
        server.cancel()
        _ = await server.result
        throw error
    }
    server.cancel()
    _ = await server.result
    if status != 0 { throw ExitCode(status) }
}

private func client(_ url: String) throws -> RingoAdminClient {
    guard let value = URL(string: url) else { throw ValidationError("Invalid gateway URL") }
    return RingoAdminClient(baseURL: value)
}

private func escaped(_ value: String) -> String { RingoAdminClient.escapedPathComponent(value) }
