import Testing
import Foundation
@testable import ClaudeAdapter

@Suite struct CountTokensTests {
    @Test func heuristicNonEmpty() {
        #expect(TokenCounter.heuristic("hello world") >= 1)
    }

    @Test func heuristicEmptyIsAtLeastOne() {
        #expect(TokenCounter.heuristic("") == 1)
    }

    @Test func heuristicOverestimatesForJapanese() {
        let s = "こんにちは世界"  // 7 chars, 21 utf8 bytes
        let h = TokenCounter.heuristic(s)
        #expect(h >= 7)
    }

    @Test func countTokensResponseEncodesSnakeCase() throws {
        let resp = CountTokensResponse(inputTokens: 1234)
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s == "{\"input_tokens\":1234}")
    }

    @Test func messagesResponseEncodesSnakeCase() throws {
        let resp = MessagesResponse(
            id: "msg_afm_x",
            model: "claude-afm-local",
            content: [ContentBlock(text: "hi")],
            stopReason: "end_turn",
            stopSequence: nil,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"stop_reason\":\"end_turn\""))
        #expect(s.contains("\"input_tokens\":10"))
        #expect(s.contains("\"output_tokens\":5"))
        #expect(s.contains("\"type\":\"message\""))
        #expect(s.contains("\"role\":\"assistant\""))
    }
}

