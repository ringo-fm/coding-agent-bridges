import Testing
import Foundation
@testable import CodexAdapter

@Suite("Responses text output")
struct ResponsesTextTests {

    @Test("OutputMapper builds a completed response with one assistant message")
    func completedResponse() {
        var diags = Diagnostics()
        let result = AFMGenerateResult(text: "Hello world", inputTokens: 10, outputTokens: 5)
        let response = OutputMapper.toResponsesObject(
            responseID: "resp_afm_01",
            model: "apple-foundation-local",
            result: result,
            createdAt: 1000,
            diagnostics: &diags
        )
        #expect(response.id == "resp_afm_01")
        #expect(response.object == "response")
        #expect(response.created_at == 1000)
        #expect(response.status == .completed)
        #expect(response.model == "apple-foundation-local")
        #expect(response.output.count == 1)
        #expect(response.output.first?.type == "message")
        #expect(response.output.first?.role == "assistant")
        #expect(response.output.first?.content?.first?.type == "output_text")
        #expect(response.output.first?.content?.first?.text == "Hello world")
        #expect(response.usage?.input_tokens == 10)
        #expect(response.usage?.output_tokens == 5)
        #expect(response.usage?.total_tokens == 15)
        #expect(!diags.estimatedUsage)
    }

    @Test("missing output tokens are estimated and flagged")
    func missingOutputTokensEstimated() {
        var diags = Diagnostics()
        let result = AFMGenerateResult(text: "abcdefgh", inputTokens: 4, outputTokens: nil)
        let response = OutputMapper.toResponsesObject(
            responseID: "resp_afm_01",
            model: "apple-foundation-local",
            result: result,
            diagnostics: &diags
        )
        #expect(diags.estimatedUsage)
        // 8 bytes / 4 = 2 tokens (lower bound 1)
        #expect(response.usage?.output_tokens == 2)
    }

    @Test("missing input tokens are estimated and flagged")
    func missingInputTokensEstimated() {
        var diags = Diagnostics()
        let result = AFMGenerateResult(text: "ok", inputTokens: nil, outputTokens: 3)
        _ = OutputMapper.toResponsesObject(
            responseID: "resp_afm_01",
            model: "apple-foundation-local",
            result: result,
            diagnostics: &diags
        )
        #expect(diags.estimatedUsage)
    }

    @Test("in-progress object has empty output and in_progress status")
    func inProgressObject() {
        let response = OutputMapper.toInProgressObject(responseID: "resp_01", model: "apple-foundation-local", createdAt: 5)
        #expect(response.status == .in_progress)
        #expect(response.output.isEmpty)
        #expect(response.id == "resp_01")
    }

    @Test("failed object wraps a BridgeError")
    func failedObject() {
        let error = BridgeError.generationFailed("boom")
        let response = OutputMapper.toFailedObject(
            responseID: "resp_01",
            model: "apple-foundation-local",
            error: error,
            createdAt: 9
        )
        #expect(response.status == .failed)
        #expect(response.error?.code == "generation_failed")
        #expect(response.error?.message.contains("boom") == true)
    }

    @Test("completed object for streaming carries final text")
    func completedObjectForStreaming() {
        var diags = Diagnostics()
        let response = OutputMapper.toCompletedObject(
            responseID: "resp_01",
            model: "apple-foundation-local",
            text: "final answer",
            inputTokens: 2,
            outputTokens: 2,
            createdAt: 7,
            diagnostics: &diags
        )
        #expect(response.status == .completed)
        #expect(response.output.first?.content?.first?.text == "final answer")
        #expect(response.usage?.total_tokens == 4)
    }

    @Test("estimateTokens handles empty and long strings")
    func estimateTokens() {
        #expect(OutputMapper.estimateTokens(text: nil) == 0)
        #expect(OutputMapper.estimateTokens(text: "") == 0)
        #expect(OutputMapper.estimateTokens(text: "ab") == 1) // 2 bytes / 4 -> max(1,0) = 1
        #expect(OutputMapper.estimateTokens(text: "abcdefgh") == 2) // 8 bytes / 4 = 2
        #expect(OutputMapper.estimateTokens(text: String(repeating: "a", count: 40)) == 10)
    }

    @Test("newID has the given prefix and no dashes")
    func newIDFormat() {
        let id = newID(prefix: "resp_afm_")
        #expect(id.hasPrefix("resp_afm_"))
        #expect(!id.contains("-"))
        #expect(id.count > "resp_afm_".count)
    }

    @Test("ResponsesInput Codable round-trips string and items")
    func responsesInputCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let asString = try encoder.encode(ResponsesInput.text("hello"))
        #expect(try decoder.decode(ResponsesInput.self, from: asString) == .text("hello"))

        let items = ResponsesInput.items([.user(text: "hi")])
        let asItems = try encoder.encode(items)
        #expect(try decoder.decode(ResponsesInput.self, from: asItems) == items)
    }

    @Test("ResponsesResponse encodes to expected JSON shape")
    func responseJSONShape() throws {
        let response = ResponsesResponse(
            id: "resp_1",
            created_at: 100,
            status: .completed,
            model: "apple-foundation-local",
            output: [ResponsesOutputItem.assistantMessage(id: "msg_1", text: "hi")]
        )
        let data = try JSONEncoder().encode(response)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"object\":\"response\""))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("\"type\":\"output_text\""))
    }
}

