import AgentBridgeCore
import Hummingbird

public struct BridgeServerConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let authToken: String?

    public init(host: String = "127.0.0.1", port: Int, authToken: String? = nil) {
        self.host = host
        self.port = port
        self.authToken = authToken
    }
}
