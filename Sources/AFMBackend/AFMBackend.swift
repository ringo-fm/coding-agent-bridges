import AgentBridgeCore

public protocol AgentModelBackend: Sendable {
    func generate(_ request: AgentGenerationRequest) async throws -> AgentGenerationResult
}

public enum AFMBackendStatus: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}
