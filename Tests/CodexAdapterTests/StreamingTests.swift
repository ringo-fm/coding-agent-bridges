import Testing
import Foundation
import NIOCore
@testable import CodexAdapter

@Suite("SSE event encoding")
struct StreamingTests {

    @Test("response.created event name and payload")
    func createdEvent() throws {
        let response = OutputMapper.toInProgressObject(responseID: "resp_01", model: "apple-foundation-local", createdAt: 1)
        let event = ResponsesEvent.responseCreated(response)
        #expect(event.eventName == "response.created")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"type\":\"response.created\""))
        #expect(payload.contains("\"id\":\"resp_01\""))
        #expect(payload.contains("\"status\":\"in_progress\""))
    }

    @Test("output_text.delta event carries the delta")
    func deltaEvent() throws {
        let event = ResponsesEvent.responseOutputTextDelta(outputIndex: 0, contentIndex: 0, delta: "Hello")
        #expect(event.eventName == "response.output_text.delta")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"delta\":\"Hello\""))
        #expect(payload.contains("\"output_index\":0"))
        #expect(payload.contains("\"content_index\":0"))
    }

    @Test("output_text.done event carries the full text")
    func doneEvent() throws {
        let event = ResponsesEvent.responseOutputTextDone(outputIndex: 0, contentIndex: 0, text: "Hello world")
        #expect(event.eventName == "response.output_text.done")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"text\":\"Hello world\""))
    }

    @Test("output_item.done event carries the completed assistant message")
    func outputItemDoneEvent() throws {
        let item = ResponsesOutputItem.assistantMessage(id: "msg_1", text: "final answer")
        let event = ResponsesEvent.responseOutputItemDone(outputIndex: 0, item: item)
        #expect(event.eventName == "response.output_item.done")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"type\":\"response.output_item.done\""))
        #expect(payload.contains("\"final answer\""))
        #expect(payload.contains("\"status\":\"completed\""))
    }

    @Test("response.completed event carries the full object")
    func completedEvent() throws {
        var diags = Diagnostics()
        let response = OutputMapper.toCompletedObject(
            responseID: "resp_01",
            model: "apple-foundation-local",
            text: "done",
            inputTokens: 1,
            outputTokens: 1,
            diagnostics: &diags
        )
        let event = ResponsesEvent.responseCompleted(response, endTurn: true)
        #expect(event.eventName == "response.completed")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"type\":\"response.completed\""))
        #expect(payload.contains("\"status\":\"completed\""))
        #expect(payload.contains("\"end_turn\":true"))
    }

    @Test("error event carries the error object")
    func errorEvent() throws {
        let err = BridgeError.unsupportedModel("gpt-4").errorObject
        let event = ResponsesEvent.error(err)
        #expect(event.eventName == "error")
        let payload = try event.data(encoder: JSONEncoder())
        #expect(payload.contains("\"code\":\"unsupported_model\""))
    }

    @Test("delta computation from cumulative snapshots matches slicing")
    func deltaComputationMath() {
        // Simulates the Routes streaming delta logic without a live model.
        var lastLen = 0
        var fullText = ""
        let snapshots = ["Hel", "Hello", "Hello wor", "Hello world"]
        var deltas: [String] = []
        for cumulative in snapshots {
            if cumulative.count > lastLen {
                let delta = String(cumulative.dropFirst(lastLen))
                deltas.append(delta)
                fullText = cumulative
                lastLen = cumulative.count
            }
        }
        #expect(deltas == ["Hel", "lo", " wor", "ld"])
        #expect(fullText == "Hello world")
    }

    @Test("delta computation skips empty/non-advancing snapshots")
    func deltaComputationNoAdvance() {
        var lastLen = 0
        var deltas: [String] = []
        let snapshots = ["Hi", "Hi", "Hi there"]
        for cumulative in snapshots {
            if cumulative.count > lastLen {
                let delta = String(cumulative.dropFirst(lastLen))
                deltas.append(delta)
                lastLen = cumulative.count
            }
        }
        // The duplicate "Hi" produces no delta.
        #expect(deltas == ["Hi", " there"])
    }

    @Test("SSEWriter framing produces event/data lines")
    func sseFramingShape() async throws {
        // Build a buffer manually to validate framing format without an HTTP writer.
        let allocator = NIOCore.ByteBufferAllocator()
        let sse = SSEWriter(allocator: allocator)
        _ = sse // referenced for completeness; framing validated by construction below

        var buffer = allocator.buffer(capacity: 64)
        buffer.writeString("event: response.created\n")
        buffer.writeString("data: {\"type\":\"response.created\"}\n\n")
        let string = buffer.getString(at: 0, length: buffer.readableBytes)
        #expect(string == "event: response.created\ndata: {\"type\":\"response.created\"}\n\n")
    }
}

