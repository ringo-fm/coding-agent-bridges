import Foundation

enum MessageID {
    static func make() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0...0xFFFFFFFF)
        return "msg_afm_" + String(ms, radix: 32) + String(rand, radix: 32)
    }
}

enum OutputMapper {
    static func toTextMessage(model: String, text: String, inputTokens: Int, outputTokens: Int, stopReason: String) -> MessagesResponse {
        MessagesResponse(
            id: MessageID.make(),
            model: model,
            content: [.text(text)],
            stopReason: stopReason,
            stopSequence: nil,
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }

    static func toToolUseMessage(model: String, toolName: String, arguments: String, inputTokens: Int, outputTokens: Int) -> MessagesResponse {
        let id = ToolMapper.makeToolUseID()
        var inputObj: [String: Any] = [:]
        if let data = arguments.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            inputObj = parsed
        }
        return MessagesResponse(
            id: MessageID.make(),
            model: model,
            content: [.toolUse(id: id, name: toolName, input: AnyCodable(inputObj))],
            stopReason: "tool_use",
            stopSequence: nil,
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }

    static func toMixedMessage(model: String, text: String?, toolName: String?, arguments: String, inputTokens: Int, outputTokens: Int) -> MessagesResponse {
        var blocks: [ContentBlock] = []
        if let text, !text.isEmpty { blocks.append(.text(text)) }
        if let toolName {
            let id = ToolMapper.makeToolUseID()
            var inputObj: [String: Any] = [:]
            if let data = arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                inputObj = parsed
            }
            blocks.append(.toolUse(id: id, name: toolName, input: AnyCodable(inputObj)))
        }
        let stopReason = toolName != nil ? "tool_use" : "end_turn"
        return MessagesResponse(
            id: MessageID.make(),
            model: model,
            content: blocks,
            stopReason: stopReason,
            stopSequence: nil,
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }
}

