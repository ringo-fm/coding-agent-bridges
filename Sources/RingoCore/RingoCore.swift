import AFMBackend
import ClaudeAdapter
import CodexAdapter
import Darwin
import Foundation
import Logging

public enum RingoAgent: String, CaseIterable, Sendable {
    case claude
    case codex

    public var defaultPort: Int {
        switch self {
        case .claude: ClaudeAdapter.defaultPort
        case .codex: CodexAdapter.defaultPort
        }
    }

    public var model: String {
        switch self {
        case .claude: ClaudeAdapter.defaultModel
        case .codex: CodexAdapter.defaultModel
        }
    }
}

public enum RingoError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case invalidAgent(String)
    case noAvailablePort
    case bridgeFailed(String)
    case bridgeTimedOut(URL)

    public var description: String {
        switch self {
        case .executableNotFound(let name): "Could not find '\(name)' on PATH."
        case .invalidAgent(let name): "Unknown agent '\(name)'; expected 'claude' or 'codex'."
        case .noAvailablePort: "Could not allocate an available localhost port."
        case .bridgeFailed(let message): "Bridge failed to start: \(message)"
        case .bridgeTimedOut(let url): "Bridge did not become ready at \(url.absoluteString)."
        }
    }
}

public struct ChildInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum RingoRuntime {
    public static let localToken = "ringo-local"

    public static func gatewayToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let configured = environment["AFM_BRIDGE_API_KEY"], !configured.isEmpty else {
            return localToken
        }
        return configured
    }

    public static func agent(named name: String) throws -> RingoAgent {
        guard let agent = RingoAgent(rawValue: name) else { throw RingoError.invalidAgent(name) }
        return agent
    }

    public static func invocation(
        for agent: RingoAgent,
        host: String,
        port: Int,
        arguments: [String],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String? = nil
    ) throws -> ChildInvocation {
        let path = try executable ?? resolveExecutable(agent.rawValue, environment: inheritedEnvironment)
        let childArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        var environment = inheritedEnvironment
        let gatewayURL = "http://\(host):\(port)"
        let token = gatewayToken(environment: inheritedEnvironment)

        switch agent {
        case .claude:
            environment["ANTHROPIC_BASE_URL"] = gatewayURL + "/anthropic"
            environment["ANTHROPIC_AUTH_TOKEN"] = token
            environment["ANTHROPIC_API_KEY"] = token
            environment["ANTHROPIC_MODEL"] = agent.model
            environment["ANTHROPIC_SMALL_FAST_MODEL"] = agent.model
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = agent.model
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = agent.model
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = agent.model
            environment["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] = "1"
            return ChildInvocation(executable: path, arguments: childArguments, environment: environment)
        case .codex:
            environment["AFM_BRIDGE_API_KEY"] = token
            let overrides = codexOverrides(baseURL: gatewayURL + "/openai/v1", model: agent.model)
            return ChildInvocation(executable: path, arguments: overrides + childArguments, environment: environment)
        }
    }

    public static func codexOverrides(baseURL: String, model: String) -> [String] {
        [
            "-c", "model=\"\(model)\"",
            "-c", "model_provider=\"ringo\"",
            "-c", "model_providers.ringo.name=\"Apple Foundation Models Local\"",
            "-c", "model_providers.ringo.base_url=\"\(baseURL)\"",
            "-c", "model_providers.ringo.wire_api=\"responses\"",
            "-c", "model_providers.ringo.env_key=\"AFM_BRIDGE_API_KEY\"",
            "-c", "model_providers.ringo.request_max_retries=0",
            "-c", "model_providers.ringo.stream_max_retries=0",
            "-c", "model_reasoning_summary=\"none\"",
            "-c", "model_supports_reasoning_summaries=false",
        ]
    }

    public static func resolveExecutable(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if name.contains("/"), FileManager.default.isExecutableFile(atPath: name) { return name }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw RingoError.executableNotFound(name)
    }

    public static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RingoError.noAvailablePort }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw RingoError.noAvailablePort }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else { throw RingoError.noAvailablePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    public static func isPortAvailable(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    public static func runBridge(agent: RingoAgent, host: String, port: Int) async throws {
        switch agent {
        case .claude:
            try await runClaudeBridge(host: host, port: port, authToken: localToken)
        case .codex:
            try await runCodexBridge(host: host, port: port, authToken: localToken)
        }
    }

    public static func runGateway(host: String, port: Int) async throws {
        try await RingoGateway.run(config: .fromEnvironment(host: host, port: port))
    }

    public static func waitUntilHealthy(host: String, port: Int, timeout: Duration = .seconds(10)) async throws {
        let url = URL(string: "http://\(host):\(port)/health")!
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 { return }
            } catch {}
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RingoError.bridgeTimedOut(url)
    }

    public static func runChild(_ invocation: ChildInvocation) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGINT) } }
        terminate.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGTERM) } }
        interrupt.resume()
        terminate.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let status = process.terminationReason == .uncaughtSignal
                    ? 128 + process.terminationStatus
                    : process.terminationStatus
                continuation.resume(returning: status)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    public static func serveInstructions(agent: RingoAgent, host: String, port: Int) -> String {
        let baseURL = "http://\(host):\(port)"
        switch agent {
        case .claude:
            return """
            Claude bridge is ready at \(baseURL)

            export ANTHROPIC_BASE_URL='\(baseURL)'
            export ANTHROPIC_AUTH_TOKEN='\(localToken)'
            export ANTHROPIC_MODEL='\(agent.model)'
            """
        case .codex:
            let command = (["codex"] + codexOverrides(baseURL: baseURL + "/v1", model: agent.model))
                .map(shellQuote).joined(separator: " ")
            return """
            Codex bridge is ready at \(baseURL)

            export AFM_BRIDGE_API_KEY='\(localToken)'
            \(command)
            """
        }
    }

    public static func gatewayServeInstructions(
        host: String,
        port: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let baseURL = "http://\(host):\(port)"
        let token = gatewayToken(environment: environment)
        let codex = (["codex"] + codexOverrides(baseURL: baseURL + "/openai/v1", model: RingoAgent.codex.model))
            .map(shellQuote).joined(separator: " ")
        return """
        Ringo gateway is ready at \(baseURL)
        Dashboard: \(baseURL)/dashboard

        Claude:
        export ANTHROPIC_BASE_URL='\(baseURL)/anthropic'
        export ANTHROPIC_AUTH_TOKEN='\(token)'

        Codex:
        export AFM_BRIDGE_API_KEY='\(token)'
        \(codex)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct DoctorCheck: Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let detail: String
}

public enum RingoDoctor {
    public static func checks(environment: [String: String] = ProcessInfo.processInfo.environment) -> [DoctorCheck] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var result = [DoctorCheck(
            name: "macOS",
            passed: os.majorVersion >= 26,
            detail: ProcessInfo.processInfo.operatingSystemVersionString
        )]
        for executable in ["swift", "xcodebuild", "claude", "codex"] {
            do {
                result.append(DoctorCheck(
                    name: executable,
                    passed: true,
                    detail: try RingoRuntime.resolveExecutable(executable, environment: environment)
                ))
            } catch {
                result.append(DoctorCheck(name: executable, passed: false, detail: "not found on PATH"))
            }
        }
        switch FoundationModelsBackend().status() {
        case .available:
            result.append(DoctorCheck(name: "Apple Foundation Models", passed: true, detail: "available"))
        case .unavailable(let reason):
            result.append(DoctorCheck(name: "Apple Foundation Models", passed: false, detail: reason))
        }
        for agent in RingoAgent.allCases {
            let port = agent.defaultPort
            result.append(DoctorCheck(
                name: "\(agent.rawValue) port",
                passed: RingoRuntime.isPortAvailable(port),
                detail: "127.0.0.1:\(port)"
            ))
        }
        return result
    }
}
