import Testing
import Foundation
import NIOCore
@testable import ClaudeAdapter

@Suite struct StreamingTests {
    @Test func deltaAppendsSuffix() {
        #expect(DeltaStreamer.delta(previous: "hello", current: "hello world") == " world")
        #expect(DeltaStreamer.delta(previous: "", current: "abc") == "abc")
        #expect(DeltaStreamer.delta(previous: "abc", current: "abc") == "")
    }

    @Test func deltaResetWhenNotPrefix() {
        #expect(DeltaStreamer.delta(previous: "abc", current: "xyz") == "xyz")
    }

    @Test func sseEventFormatting() {
        let allocator = ByteBufferAllocator()
        let buf = SSEWriter.event("content_block_delta", payload: ContentBlockDeltaEvent(index: 0, text: "hi"), allocator: allocator)
        let str = String(buffer: buf)
        #expect(str.hasPrefix("event: content_block_delta\n"))
        #expect(str.contains("data: {"))
        #expect(str.hasSuffix("\n\n"))
        #expect(str.contains("\"type\":\"content_block_delta\""))
        #expect(str.contains("\"text\":\"hi\""))
    }

    @Test func messageStartEventShape() throws {
        let event = MessageStartEvent(id: "msg_afm_test", model: "claude-afm-local", inputTokens: 12)
        let data = try JSONEncoder().encode(event)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"message_start\""))
        #expect(s.contains("\"id\":\"msg_afm_test\""))
        #expect(s.contains("\"input_tokens\":12"))
        #expect(s.contains("\"output_tokens\":1"))
        #expect(s.contains("\"stop_reason\":null"))
    }

    @Test func messageDeltaEventShape() throws {
        let event = MessageDeltaEvent(stopReason: "end_turn", outputTokens: 42)
        let data = try JSONEncoder().encode(event)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"message_delta\""))
        #expect(s.contains("\"stop_reason\":\"end_turn\""))
        #expect(s.contains("\"output_tokens\":42"))
    }

    @Test func toolUseStreamingEventShape() {
        let allocator = ByteBufferAllocator()
        let start = String(buffer: SSEWriter.event(
            "content_block_start",
            payload: ContentBlockStartEvent(index: 1, toolUseId: "toolu_afm_test", toolName: "Bash"),
            allocator: allocator
        ))
        let delta = String(buffer: SSEWriter.event(
            "content_block_delta",
            payload: ContentBlockDeltaEvent(index: 1, partialJson: "{\"command\":\"pwd\"}"),
            allocator: allocator
        ))
        let done = String(buffer: SSEWriter.event(
            "message_delta",
            payload: MessageDeltaEvent(stopReason: "tool_use", outputTokens: 8),
            allocator: allocator
        ))

        #expect(start.contains("\"type\":\"tool_use\""))
        #expect(start.contains("\"id\":\"toolu_afm_test\""))
        #expect(start.contains("\"name\":\"Bash\""))
        #expect(delta.contains("\"type\":\"input_json_delta\""))
        #expect(delta.contains("\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\""))
        #expect(done.contains("\"stop_reason\":\"tool_use\""))
    }
}

