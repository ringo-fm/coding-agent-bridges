import Testing
import Foundation
@testable import ClaudeAdapter

@Suite struct OutputMapperTests {
    @Test func toTextMessageShape() throws {
        let resp = OutputMapper.toTextMessage(model: "claude-afm-local", text: "hello", inputTokens: 10, outputTokens: 5, stopReason: "end_turn")
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"text\""))
        #expect(s.contains("\"text\":\"hello\""))
        #expect(s.contains("\"stop_reason\":\"end_turn\""))
    }

    @Test func toToolUseMessageShape() throws {
        let resp = OutputMapper.toToolUseMessage(model: "claude-afm-local", toolName: "Bash", arguments: "{\"command\":\"ls\"}", inputTokens: 10, outputTokens: 5)
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"tool_use\""))
        #expect(s.contains("\"name\":\"Bash\""))
        #expect(s.contains("\"command\":\"ls\""))
        #expect(s.contains("\"stop_reason\":\"tool_use\""))
        #expect(s.contains("toolu_afm_"))
    }

    @Test func toMixedMessageWithTextAndTool() throws {
        let resp = OutputMapper.toMixedMessage(model: "claude-afm-local", text: "Running it.", toolName: "Bash", arguments: "{\"command\":\"pwd\"}", inputTokens: 10, outputTokens: 5)
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"text\""))
        #expect(s.contains("Running it."))
        #expect(s.contains("\"type\":\"tool_use\""))
        #expect(s.contains("\"stop_reason\":\"tool_use\""))
    }

    @Test func toMixedMessageWithOnlyText() throws {
        let resp = OutputMapper.toMixedMessage(model: "claude-afm-local", text: "Just text.", toolName: nil, arguments: "{}", inputTokens: 10, outputTokens: 5)
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"text\""))
        #expect(!s.contains("tool_use"))
        #expect(s.contains("\"stop_reason\":\"end_turn\""))
    }
}

