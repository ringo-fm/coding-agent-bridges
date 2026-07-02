import AFMBackend
import AgentBridgeCore
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
    case invalidContextMode(String)
    case noAvailablePort
    case bridgeFailed(String)
    case bridgeTimedOut(URL)

    public var description: String {
        switch self {
        case .executableNotFound(let name): "Could not find '\(name)' on PATH."
        case .invalidAgent(let name): "Unknown agent '\(name)'; expected 'claude' or 'codex'."
        case .invalidContextMode(let name): "Unknown context mode '\(name)'; expected 'persistent', 'memory', or 'off'."
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
    public static let defaultMaxToolSteps = 6

    public static var defaultCodexHome: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("coding-agent-bridges/codex-home", isDirectory: true).path
    }

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
        executable: String? = nil,
        inheritCodexConfig: Bool = false,
        codexHome: String? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> ChildInvocation {
        let path = try executable ?? resolveRunnableExecutable(agent.rawValue, environment: inheritedEnvironment)
        var childArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
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
            if childArguments.first == "exec",
               !childArguments.contains("--skip-git-repo-check"),
               !isInsideGitRepository(at: workingDirectory) {
                childArguments.insert("--skip-git-repo-check", at: 1)
            }
            environment["AFM_BRIDGE_API_KEY"] = token
            let resolvedCodexHome: String?
            if !inheritCodexConfig {
                resolvedCodexHome = codexHome ?? defaultCodexHome
                environment["CODEX_HOME"] = resolvedCodexHome
            } else {
                resolvedCodexHome = nil
            }
            let catalogPath = resolvedCodexHome.map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("models.json").path
            }
            let overrides = codexOverrides(
                baseURL: gatewayURL + "/openai/v1",
                model: agent.model,
                modelCatalogPath: catalogPath
            )
            return ChildInvocation(executable: path, arguments: overrides + childArguments, environment: environment)
        }
    }

    public static func codexOverrides(
        baseURL: String,
        model: String,
        modelCatalogPath: String? = nil,
        contextSize: Int = FoundationModelsBackend().contextSize
    ) -> [String] {
        let compactLimit = max(1, contextSize * 3 / 4)
        let toolOutputLimit = max(1, contextSize / 4)
        var overrides = [
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
            "-c", "personality=\"none\"",
            "-c", "features.personality=false",
            "-c", "web_search=\"disabled\"",
            "-c", "model_context_window=\(contextSize)",
            "-c", "model_auto_compact_token_limit=\(compactLimit)",
            "-c", "tool_output_token_limit=\(toolOutputLimit)",
        ]
        if let modelCatalogPath {
            overrides += [
                "-c", "model_catalog_json=\"\(modelCatalogPath)\"",
                "-c", "features.plugins=false",
                "-c", "features.apps=false",
                "-c", "features.browser_use=false",
                "-c", "features.browser_use_external=false",
                "-c", "features.computer_use=false",
                "-c", "features.image_generation=false",
                "-c", "features.in_app_browser=false",
                "-c", "features.multi_agent=false",
                "-c", "features.workspace_dependencies=false",
            ]
        }
        return overrides
    }

    public static func prepareCodexHome(at path: String = defaultCodexHome) throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ModelsList.runtime(contextSize: FoundationModelsBackend().contextSize)).write(
            to: directory.appendingPathComponent("models.json"),
            options: .atomic
        )
    }

    public static func isInsideGitRepository(at path: String) -> Bool {
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            if directory == root { return false }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return false }
            directory = parent
        }
    }

    public static func gatewayConfiguration(
        host: String,
        port: Int,
        contextMode: String,
        verbose: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GatewayConfiguration {
        guard let mode = ContextStorageMode(rawValue: contextMode) else {
            throw RingoError.invalidContextMode(contextMode)
        }
        return GatewayConfiguration(
            host: host,
            port: port,
            authToken: gatewayToken(environment: environment),
            contextMode: mode,
            contextPath: environment["AFM_BRIDGE_CONTEXT_PATH"],
            retentionDays: Int(environment["AFM_BRIDGE_CONTEXT_RETENTION_DAYS"] ?? "30") ?? 30,
            verbose: verbose
        )
    }

    public static func runCodexExecClean(_ invocation: ChildInvocation) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        var arguments = invocation.arguments
        if let execIndex = arguments.firstIndex(of: "exec"), !arguments.contains("--json") {
            arguments.insert("--json", at: execIndex + 1)
        }
        process.arguments = arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.standardInput
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        try process.run()
        async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd()
        async let stderrData = stderrPipe.fileHandleForReading.readToEnd()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationReason == .uncaughtSignal
                    ? 128 + process.terminationStatus
                    : process.terminationStatus)
            }
        }
        let (stdout, stderr) = try await (stdoutData, stderrData)
        let output = stdout.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errorOutput = stderr.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let final = finalAgentMessage(from: output), !final.isEmpty {
            FileHandle.standardOutput.write(Data((final + "\n").utf8))
        } else if status != 0 {
            FileHandle.standardError.write(Data((errorOutput.isEmpty ? output : errorOutput).utf8))
        }
        return status
    }

    public static func finalAgentMessage(from jsonLines: String) -> String? {
        let messages = jsonLines.split(separator: "\n").compactMap { line -> String? in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "item.completed",
                  let item = object["item"] as? [String: Any],
                  item["type"] as? String == "agent_message" else {
                return nil
            }
            return item["text"] as? String
        }
        return messages.last
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

    public static func resolveRunnableExecutable(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var candidates: [String] = []
        if let path = try? resolveExecutable(name, environment: environment) { candidates.append(path) }
        if name == "codex" {
            candidates.append("/Applications/Codex.app/Contents/Resources/codex")
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if (try? executableVersion(candidate, environment: environment)) != nil { return candidate }
        }
        throw RingoError.executableNotFound(name)
    }

    public static func executableVersion(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RingoError.executableNotFound(path) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? path
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

    public static func runGateway(config: GatewayConfiguration) async throws {
        try await RingoGateway.run(config: config)
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
        var masterFD: Int32 = -1
        var ws = winsize()
        if isatty(STDIN_FILENO) != 0 {
            _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws)
        } else {
            ws.ws_col = 80
            ws.ws_row = 24
        }

        let pid = forkpty(&masterFD, nil, nil, &ws)
        guard pid >= 0 else {
            throw RingoError.bridgeFailed("forkpty failed: \(String(cString: strerror(errno)))")
        }

        if pid == 0 {
            // Child: inherit environment then override with bridge values
            for (key, value) in invocation.environment {
                setenv(key, value, 1)
            }
            let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
            execv(invocation.executable, argv)
            _exit(127)
        }

        // Parent: save/restore terminal, set up signal forwarding, relay I/O via poll loop
        var originalTermios = termios()
        let stdinIsTTY = isatty(STDIN_FILENO) != 0
        if stdinIsTTY {
            tcgetattr(STDIN_FILENO, &originalTermios)
            var raw = originalTermios
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGWINCH, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let sigwinchSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        sigintSrc.setEventHandler { kill(pid, SIGINT) }
        sigtermSrc.setEventHandler { kill(pid, SIGTERM) }
        sigwinchSrc.setEventHandler {
            var newWS = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &newWS) == 0 {
                _ = ioctl(masterFD, TIOCSWINSZ, &newWS)
            }
        }
        sigintSrc.resume()
        sigtermSrc.resume()
        sigwinchSrc.resume()

        // I/O relay runs on a dedicated thread using poll() to avoid blocking async runtime
        let relayThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                var fds = [
                    pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                ]
                let ret = poll(&fds, 2, 50)
                if ret < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // masterFD → stdout: drain first, then check for hangup
                if fds[0].revents & Int16(POLLIN) != 0 {
                    let n = read(masterFD, &buf, buf.count)
                    if n > 0 { _ = write(STDOUT_FILENO, &buf, n) }
                    else if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { break }
                }
                if fds[0].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 { break }
                // stdin → masterFD
                if fds[1].revents & Int16(POLLIN) != 0 {
                    let n = read(STDIN_FILENO, &buf, buf.count)
                    if n > 0 { _ = write(masterFD, &buf, n) }
                    else if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { break }
                }
            }
        }
        relayThread.start()

        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var exitStatus: Int32 = 0
                waitpid(pid, &exitStatus, 0)
                let wstatus = exitStatus & 0x7f
                let code: Int32
                if wstatus == 0 {
                    code = (exitStatus >> 8) & 0xff
                } else if wstatus != 0x7f {
                    code = 128 + wstatus
                } else {
                    code = exitStatus
                }
                continuation.resume(returning: code)
            }
        }

        close(masterFD)
        sigintSrc.cancel()
        sigtermSrc.cancel()
        sigwinchSrc.cancel()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)

        if stdinIsTTY {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        }

        return status
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
                let path = try RingoRuntime.resolveRunnableExecutable(executable, environment: environment)
                let version = try RingoRuntime.executableVersion(path, environment: environment)
                result.append(DoctorCheck(
                    name: executable,
                    passed: true,
                    detail: "\(version) (\(path))"
                ))
            } catch {
                result.append(DoctorCheck(name: executable, passed: false, detail: "not found on PATH"))
            }
        }
        let backend = FoundationModelsBackend()
        switch backend.status() {
        case .available:
            result.append(DoctorCheck(
                name: "Apple Foundation Models",
                passed: true,
                detail: "available; context=\(backend.capabilities.contextSize); exact-token-counting=\(backend.capabilities.exactTokenCounting)"
            ))
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
