import Foundation

struct MessageStartEvent: Codable {
    let type: String
    let message: MessageBody

    struct MessageBody: Codable {
        let id: String
        let type: String
        let role: String
        let content: [ContentBlock]
        let model: String
        let stopReason: String?
        let stopSequence: String?
        let usage: Usage

        enum CodingKeys: String, CodingKey {
            case id, type, role, content, model
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
            case usage
        }

        init(id: String, model: String, inputTokens: Int) {
            self.id = id
            self.type = "message"
            self.role = "assistant"
            self.content = []
            self.model = model
            self.stopReason = nil
            self.stopSequence = nil
            self.usage = Usage(inputTokens: inputTokens, outputTokens: 1)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.type = try c.decode(String.self, forKey: .type)
            self.role = try c.decode(String.self, forKey: .role)
            self.content = try c.decode([ContentBlock].self, forKey: .content)
            self.model = try c.decode(String.self, forKey: .model)
            self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
            self.stopSequence = try c.decodeIfPresent(String.self, forKey: .stopSequence)
            self.usage = try c.decode(Usage.self, forKey: .usage)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(type, forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
            try c.encode(model, forKey: .model)
            if let sr = stopReason { try c.encode(sr, forKey: .stopReason) } else { try c.encodeNil(forKey: .stopReason) }
            if let ss = stopSequence { try c.encode(ss, forKey: .stopSequence) } else { try c.encodeNil(forKey: .stopSequence) }
            try c.encode(usage, forKey: .usage)
        }
    }

    init(id: String, model: String, inputTokens: Int) {
        self.type = "message_start"
        self.message = MessageBody(id: id, model: model, inputTokens: inputTokens)
    }
}

struct ContentBlockStartEvent: Codable {
    let type: String
    let index: Int
    let contentBlock: ContentBlock

    enum CodingKeys: String, CodingKey {
        case type, index
        case contentBlock = "content_block"
    }

    init(index: Int, text: String = "") {
        self.type = "content_block_start"
        self.index = index
        self.contentBlock = .text(text)
    }

    init(index: Int, toolUseId: String, toolName: String) {
        self.type = "content_block_start"
        self.index = index
        self.contentBlock = .toolUse(id: toolUseId, name: toolName, input: AnyCodable([:]))
    }
}

struct ContentBlockDeltaEvent: Codable {
    let type: String
    let index: Int
    let delta: DeltaPayload

    enum CodingKeys: String, CodingKey {
        case type, index, delta
    }

    enum DeltaPayload: Codable {
        case textDelta(text: String)
        case inputJSONDelta(partialJson: String)

        enum CodingKeys: String, CodingKey {
            case type, text, partialJson = "partial_json"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let dt = try c.decode(String.self, forKey: .type)
            switch dt {
            case "text_delta": self = .textDelta(text: try c.decode(String.self, forKey: .text))
            case "input_json_delta": self = .inputJSONDelta(partialJson: try c.decode(String.self, forKey: .partialJson))
            default: self = .textDelta(text: "")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .textDelta(let text):
                try c.encode("text_delta", forKey: .type)
                try c.encode(text, forKey: .text)
            case .inputJSONDelta(let partialJson):
                try c.encode("input_json_delta", forKey: .type)
                try c.encode(partialJson, forKey: .partialJson)
            }
        }
    }

    init(index: Int, text: String) {
        self.type = "content_block_delta"
        self.index = index
        self.delta = .textDelta(text: text)
    }

    init(index: Int, partialJson: String) {
        self.type = "content_block_delta"
        self.index = index
        self.delta = .inputJSONDelta(partialJson: partialJson)
    }
}

struct ContentBlockStopEvent: Codable {
    let type: String
    let index: Int
    init(index: Int) { self.type = "content_block_stop"; self.index = index }
}

struct MessageDeltaEvent: Codable {
    let type: String
    let delta: DeltaBody
    let usage: OutputUsage

    struct DeltaBody: Codable {
        let stopReason: String?
        let stopSequence: String?

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
        }
    }

    struct OutputUsage: Codable {
        let outputTokens: Int
        enum CodingKeys: String, CodingKey { case outputTokens = "output_tokens" }
    }

    init(stopReason: String, outputTokens: Int) {
        self.type = "message_delta"
        self.delta = DeltaBody(stopReason: stopReason, stopSequence: nil)
        self.usage = OutputUsage(outputTokens: outputTokens)
    }
}

struct MessageStopEvent: Codable {
    let type: String
    init() { self.type = "message_stop" }
}

struct PingEvent: Codable {
    let type: String
    init() { self.type = "ping" }
}

