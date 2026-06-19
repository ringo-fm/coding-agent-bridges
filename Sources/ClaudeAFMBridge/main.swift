import ArgumentParser
import ClaudeAdapter

@main
struct BridgeApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "claude-afm-bridge")

    @Option(name: .shortAndLong) var host: String?
    @Option(name: .shortAndLong) var port: Int?
    @Option(name: .long) var authToken: String?
    @Option(name: .long) var logLevel: String?
    @Flag(name: .shortAndLong) var debug = false

    func run() async throws {
        let config = BridgeConfig.resolve(
            host: host,
            port: port,
            authToken: authToken,
            logLevel: logLevel,
            debug: debug
        )
        let app = try await buildApplication(config: config)
        try await app.runService()
    }
}
