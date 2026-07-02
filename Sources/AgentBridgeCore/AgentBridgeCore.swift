import Foundation

public enum AgentRole: String, Codable, Sendable {
    case system
    case developer
    case user
    case assistant
    case tool
}

public struct AgentMessage: Codable, Sendable, Equatable {
    public let role: AgentRole
    public let text: String

    public init(role: AgentRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AgentToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public struct AgentToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public enum AgentToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case tool(String)
}

public enum AgentExecutionStrategy: String, Codable, Sendable, Equatable {
    case adaptive
    case direct
    case staged
}

public struct AgentRuntimeCapabilities: Codable, Sendable, Equatable {
    public let contextSize: Int
    public let exactTokenCounting: Bool
    public let structuredGeneration: Bool
    public let sessionReuse: Bool
    public let transcriptRehydration: Bool
    public let streaming: Bool

    public init(
        contextSize: Int,
        exactTokenCounting: Bool,
        structuredGeneration: Bool = true,
        sessionReuse: Bool = true,
        transcriptRehydration: Bool = true,
        streaming: Bool = true
    ) {
        self.contextSize = contextSize
        self.exactTokenCounting = exactTokenCounting
        self.structuredGeneration = structuredGeneration
        self.sessionReuse = sessionReuse
        self.transcriptRehydration = transcriptRehydration
        self.streaming = streaming
    }
}

public struct AgentGenerationRequest: Sendable, Equatable {
    public let model: String
    public let messages: [AgentMessage]
    public let tools: [AgentToolDefinition]
    public let stream: Bool
    public let maximumOutputTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let conversationKey: String?
    public let contextFingerprint: String?
    public let resultingContextFingerprint: String?
    public let incrementalMessages: [AgentMessage]?
    public let decisionContext: String?
    public let toolChoice: AgentToolChoice
    public let executionStrategy: AgentExecutionStrategy

    public init(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        stream: Bool = false,
        maximumOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        conversationKey: String? = nil,
        contextFingerprint: String? = nil,
        resultingContextFingerprint: String? = nil,
        incrementalMessages: [AgentMessage]? = nil,
        decisionContext: String? = nil,
        toolChoice: AgentToolChoice = .auto,
        executionStrategy: AgentExecutionStrategy = .adaptive
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.conversationKey = conversationKey
        self.contextFingerprint = contextFingerprint
        self.resultingContextFingerprint = resultingContextFingerprint
        self.incrementalMessages = incrementalMessages
        self.decisionContext = decisionContext
        self.toolChoice = toolChoice
        self.executionStrategy = executionStrategy
    }
}

public struct AgentGenerationResult: Sendable, Equatable {
    public let text: String
    public let toolCalls: [AgentToolCall]
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(
        text: String,
        toolCalls: [AgentToolCall] = [],
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AgentStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(AgentToolCall)
    case completed(AgentGenerationResult)
}

public enum AgentBackendError: Error, Sendable, Equatable {
    case unavailable(String)
    case contextTooLarge(limit: Int)
    case cancelled
    case generationFailed(String)
}
