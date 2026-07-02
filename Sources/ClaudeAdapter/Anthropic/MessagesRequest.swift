import Foundation
import AgentBridgeCore

struct MessagesRequest: Decodable {
    let model: String
    let maxTokens: Int?
    let system: SystemPrompt?
    let messages: [Message]
    let stream: Bool?
    let temperature: Double?
    let topP: Double?
    let tools: [ToolDefinition]?
    let toolChoice: ClaudeToolChoice?
    let thinkingPresent: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
        case temperature
        case topP = "top_p"
        case tools
        case toolChoice = "tool_choice"
        case thinking
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.system = try c.decodeIfPresent(SystemPrompt.self, forKey: .system)
        self.messages = try c.decode([Message].self, forKey: .messages)
        self.stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        self.tools = try c.decodeIfPresent([ToolDefinition].self, forKey: .tools)
        self.toolChoice = try c.decodeIfPresent(ClaudeToolChoice.self, forKey: .toolChoice)
        self.thinkingPresent = c.contains(.thinking)
    }

    var toolsPresent: Bool { tools != nil }
    var hasTools: Bool { !(tools?.isEmpty ?? true) }
    var toolChoicePresent: Bool { toolChoice != nil }
}

struct ClaudeToolChoice: Decodable {
    let type: String
    let name: String?

    var agentChoice: AgentToolChoice {
        switch type {
        case "none": .none
        case "any": .required
        case "tool": name.map(AgentToolChoice.tool) ?? .required
        default: .auto
        }
    }
}

enum SystemPrompt: Decodable {
    case text(String)
    case blocks([SystemTextBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .blocks(try container.decode([SystemTextBlock].self))
        }
    }

    var flattenedText: String {
        switch self {
        case .text(let s): return s
        case .blocks(let bs): return bs.compactMap { $0.text }.joined(separator: "\n\n")
        }
    }
}

struct SystemTextBlock: Decodable {
    let type: String
    let text: String?
}

struct Message: Decodable {
    let role: String
    let content: MessageContent

    enum CodingKeys: String, CodingKey { case role, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try MessageContent(from: try c.superDecoder(forKey: .content))
    }
}

enum MessageContent: Decodable {
    case text(String)
    case blocks([RequestContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .blocks(try container.decode([RequestContentBlock].self))
        }
    }

    var blockList: [RequestContentBlock] {
        switch self {
        case .text(let s): return [.text(s)]
        case .blocks(let bs): return bs
        }
    }

    var allText: String {
        blockList.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }
}

enum RequestContentBlock: Decodable {
    case text(String)
    case toolResult(ToolResultBlock)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey { case type, text, thinking }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .thinking) ?? "")
        default:
            self = .unknown(type: type)
        }
    }
}

struct ToolResultBlock: Decodable {
    let type: String
    let toolUseId: String
    let content: ToolResultContent?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    var flattenedContent: String {
        guard let content else { return "" }
        switch content {
        case .text(let s): return s
        case .blocks(let bs):
            return bs.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
        }
    }
}

enum ToolResultContent: Decodable {
    case text(String)
    case blocks([RequestContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .blocks(try container.decode([RequestContentBlock].self))
        }
    }
}

struct ToolUseBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
    let input: AnyDecodable?

    enum CodingKeys: String, CodingKey { case type, id, name, input }

    var inputJSON: String? {
        guard let input = input else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: input.value), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return nil
    }
}

struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self.value = v }
        else if let v = try? container.decode(Int.self) { self.value = v }
        else if let v = try? container.decode(Double.self) { self.value = v }
        else if let v = try? container.decode(String.self) { self.value = v }
        else if let v = try? container.decode([AnyDecodable].self) { self.value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyDecodable].self) { self.value = v.mapValues { $0.value } }
        else { self.value = NSNull() }
    }
}
