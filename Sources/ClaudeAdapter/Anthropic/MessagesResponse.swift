import Foundation

struct MessagesResponse: Codable {
    let id: String
    let type: String
    let role: String
    let model: String
    let content: [ContentBlock]
    let stopReason: String?
    let stopSequence: String?
    let usage: Usage

    enum CodingKeys: String, CodingKey {
        case id, type, role, model, content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }

    init(id: String, model: String, content: [ContentBlock], stopReason: String?, stopSequence: String?, usage: Usage) {
        self.id = id
        self.type = "message"
        self.role = "assistant"
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.type = try c.decode(String.self, forKey: .type)
        self.role = try c.decode(String.self, forKey: .role)
        self.model = try c.decode(String.self, forKey: .model)
        self.content = try c.decode([ContentBlock].self, forKey: .content)
        self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        self.stopSequence = try c.decodeIfPresent(String.self, forKey: .stopSequence)
        self.usage = try c.decode(Usage.self, forKey: .usage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(role, forKey: .role)
        try c.encode(model, forKey: .model)
        try c.encode(content, forKey: .content)
        if let sr = stopReason { try c.encode(sr, forKey: .stopReason) } else { try c.encodeNil(forKey: .stopReason) }
        if let ss = stopSequence { try c.encode(ss, forKey: .stopSequence) } else { try c.encodeNil(forKey: .stopSequence) }
        try c.encode(usage, forKey: .usage)
    }
}

enum ContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: AnyCodable)

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }

    init(text: String) { self = .text(text) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = (try? c.decode(AnyCodable.self, forKey: .input)) ?? AnyCodable([:])
            self = .toolUse(id: id, name: name, input: input)
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        }
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self.value = v }
        else if let v = try? container.decode(Int.self) { self.value = v }
        else if let v = try? container.decode(Double.self) { self.value = v }
        else if let v = try? container.decode(String.self) { self.value = v }
        else if let v = try? container.decode([AnyCodable].self) { self.value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyCodable].self) { self.value = v.mapValues { $0.value } }
        else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try container.encode(v.mapValues { AnyCodable($0) })
        case let v as [String: AnyCodable]: try container.encode(v)
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}

struct Usage: Codable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

