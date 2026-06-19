import Foundation

struct CountTokensRequest: Decodable {
    let model: String?
    let system: SystemPrompt?
    let messages: [Message]?
    let toolsPresent: Bool
    let thinkingPresent: Bool

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, thinking
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.system = try c.decodeIfPresent(SystemPrompt.self, forKey: .system)
        self.messages = try c.decodeIfPresent([Message].self, forKey: .messages)
        self.toolsPresent = c.contains(.tools)
        self.thinkingPresent = c.contains(.thinking)
    }
}

struct CountTokensResponse: Codable {
    let inputTokens: Int

    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
}

