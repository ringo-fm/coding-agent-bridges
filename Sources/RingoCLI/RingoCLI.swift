import Darwin
import Foundation

@main
struct RingoCLI {
    static func main() {
        do {
            Darwin.exit(try run(Array(CommandLine.arguments.dropFirst())))
        } catch let error as CLIError {
            fputs("ringo: \(error.message)\n", stderr)
            Darwin.exit(error.code)
        } catch {
            fputs("ringo: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    static func run(_ args: [String]) throws -> Int32 {
        guard let first = args.first else { print(help); return 0 }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "-h", "--help": print(help); return 0
        case "doctor": return doctor()
        case "serve":
            guard let agent = rest.first.flatMap(Agent.init(rawValue:)) else {
                throw CLIError("usage: ringo serve <codex|claude> [-- <bridge-args>...]", 64)
            }
            return try runProcess(resolveBridge(agent), Array(rest.dropFirst()).dropLeadingDashDash())
        case "run":
            guard let agent = rest.first.flatMap(Agent.init(rawValue:)) else {
                throw CLIError("usage: ringo run <codex|claude> [-- <agent-args>...]", 64)
            }
            return try runAgent(agent, Array(rest.dropFirst()).dropLeadingDashDash())
        case "codex", "claude":
            return try runAgent(Agent(rawValue: first)!, rest.dropLeadingDashDash())
        default:
            throw CLIError("unknown command: \(first)", 64)
        }
    }

    static func runAgent(_ agent: Agent, _ agentArgs: [String]) throws -> Int32 {
        let host = env("AFM_BRIDGE_HOST") ?? "127.0.0.1"
        let port = env("AFM_BRIDGE_PORT") ?? String(agent.defaultPort)
        let token = env("AFM_BRIDGE_API_KEY") ?? "ringo-\(UUID().uuidString)"
        let bridgePath = try resolveBridge(agent)
        let agentPath = try resolveCommand(agent.rawValue)
        let baseURL = "http://\(host):\(port)"

        var bridgeEnv = ProcessInfo.processInfo.environment
        bridgeEnv["AFM_BRIDGE_HOST"] = host
        bridgeEnv["AFM_BRIDGE_PORT"] = port
        bridgeEnv["AFM_BRIDGE_API_KEY"] = token

        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: bridgePath)
        bridge.environment = bridgeEnv
        try bridge.run()

        let agentRef = UnsafeMutablePointer<Process?>.allocate(capacity: 1)
        agentRef.initialize(to: nil)
        defer { agentRef.deallocate() }

        installSignalHandler(bridge: bridge, agentRef: agentRef)
        defer {
            if bridge.isRunning {
                bridge.terminate()
                bridge.waitUntilExit()
            }
        }

        if !waitForBridge(baseURL, bridge: bridge) {
            throw CLIError("bridge did not become ready at \(baseURL)", 70)
        }

        var agentEnv = ProcessInfo.processInfo.environment
        if agent == .codex {
            agentEnv["OPENAI_API_KEY"] = token
            agentEnv["OPENAI_BASE_URL"] = "\(baseURL)/v1"
            agentEnv["OPENAI_RESPONSES_BASE_URL"] = "\(baseURL)/v1"
        } else {
            agentEnv["ANTHROPIC_API_KEY"] = token
            agentEnv["ANTHROPIC_BASE_URL"] = baseURL
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: agentPath)
        child.arguments = agentArgs
        child.environment = agentEnv
        agentRef.pointee = child
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }

    private static func installSignalHandler(bridge: Process, agentRef: UnsafeMutablePointer<Process?>) {
        _bridgeProcess = bridge
        _agentProcessRef = agentRef
        for sig: Int32 in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                _agentProcessRef?.pointee?.terminate()
                if _bridgeProcess?.isRunning == true { _bridgeProcess?.terminate() }
                Darwin.exit(130)
            }
        }
    }

    static func doctor() -> Int32 {
        var failed = false
        func line(_ ok: Bool, _ name: String, _ value: String) {
            print("\(ok ? "ok" : "fail")  \(name): \(value)")
            if !ok { failed = true }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        line(os.majorVersion >= 26, "macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion), required >= 26")
        for name in ["swift", "codex", "claude", "codex-afm-bridge", "claude-afm-bridge"] {
            if let path = findOnPATH(name) {
                line(true, name, path)
            } else {
                line(false, name, "not found on PATH")
            }
        }
        if env("AFM_BRIDGE_API_KEY") == nil {
            line(true, "bridge token", "will be generated for ringo run")
        } else {
            line(true, "bridge token", "provided by environment")
        }
        return failed ? 1 : 0
    }

    static func resolveBridge(_ agent: Agent) throws -> String {
        if let override = env(agent.bridgeEnv), !override.isEmpty { return try resolveCommand(override) }
        if let sibling = siblingExecutable(agent.bridgeExecutable) { return sibling }
        return try resolveCommand(agent.bridgeExecutable)
    }

    static func runProcess(_ path: String, _ args: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let environment { process.environment = environment }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func waitForBridge(_ baseURL: String, bridge: Process? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        let curl = findOnPATH("curl") ?? "/usr/bin/curl"
        while Date() < deadline {
            if let bridge, !bridge.isRunning { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: curl)
            process.arguments = ["--silent", "--show-error", "--fail", "--max-time", "1", baseURL + "/health"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            } catch {
                return false
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    static func resolveCommand(_ command: String) throws -> String {
        if command.contains("/") {
            let path = command.replacingOccurrences(of: "~/", with: FileManager.default.homeDirectoryForCurrentUser.path + "/")
            if FileManager.default.isExecutableFile(atPath: path) { return path }
            throw CLIError("executable not found: \(command)", 66)
        }
        if let path = findOnPATH(command) { return path }
        throw CLIError("executable not found on PATH: \(command)", 66)
    }

    static func findOnPATH(_ name: String) -> String? {
        for dir in (env("PATH") ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func siblingExecutable(_ name: String) -> String? {
        let invoked = CommandLine.arguments[0]
        let base = invoked.hasPrefix("/") ? URL(fileURLWithPath: invoked) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(invoked)
        let path = base.deletingLastPathComponent().appendingPathComponent(name).standardized.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    static let help = """
    ringo - run Codex or Claude Code through local Apple Foundation Models bridges

    Usage:
      ringo codex [-- <codex-args>...]
      ringo claude [-- <claude-args>...]
      ringo run <codex|claude> [-- <agent-args>...]
      ringo serve <codex|claude> [-- <bridge-args>...]
      ringo doctor

    Environment:
      AFM_BRIDGE_HOST=127.0.0.1
      AFM_BRIDGE_PORT=<default: 8765 for codex, 8766 for claude>
      AFM_BRIDGE_API_KEY=<local-token>
      RINGO_CODEX_BRIDGE=/path/to/codex-afm-bridge
      RINGO_CLAUDE_BRIDGE=/path/to/claude-afm-bridge
    """
}

private nonisolated(unsafe) var _bridgeProcess: Process?
private nonisolated(unsafe) var _agentProcessRef: UnsafeMutablePointer<Process?>?

enum Agent: String {
    case codex
    case claude

    var defaultPort: Int { self == .codex ? 8765 : 8766 }
    var bridgeExecutable: String { self == .codex ? "codex-afm-bridge" : "claude-afm-bridge" }
    var bridgeEnv: String { self == .codex ? "RINGO_CODEX_BRIDGE" : "RINGO_CLAUDE_BRIDGE" }
}

struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, _ code: Int32 = 1) { self.message = message; self.code = code }
}

extension Array where Element == String {
    func dropLeadingDashDash() -> [String] {
        first == "--" ? Array(dropFirst()) : self
    }
}
