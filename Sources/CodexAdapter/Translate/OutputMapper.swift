import Foundation

/// Maps AFM generation results back into Responses API objects.
public enum OutputMapper {
    /// Build a completed `ResponsesResponse` for a non-streaming result.
    public static func toResponsesObject(
        responseID: String,
        model: String,
        result: AFMGenerateResult,
        createdAt: Int = Int(Date().timeIntervalSince1970),
        diagnostics: inout Diagnostics
    ) -> ResponsesResponse {
        let messageID = newID(prefix: "msg_afm_")
        let message = ResponsesOutputItem.assistantMessage(id: messageID, text: result.text)

        // Build function_call items for any captured tool calls.
        var output: [ResponsesOutputItem] = [message]
        for call in result.toolCalls {
            let callID = newID(prefix: "call_afm_")
            let fcID = newID(prefix: "fc_afm_")
            output.append(ResponsesOutputItem.functionCall(
                id: fcID,
                callID: callID,
                name: call.name,
                arguments: call.argumentsJSON
            ))
        }

        let usage: ResponsesUsage? = makeUsage(
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            text: result.text,
            diagnostics: &diagnostics
        )

        return ResponsesResponse(
            id: responseID,
            created_at: createdAt,
            status: .completed,
            model: model,
            output: output,
            usage: usage
        )
    }

    /// Build an in-progress response skeleton used for the first SSE events.
    public static func toInProgressObject(
        responseID: String,
        model: String,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) -> ResponsesResponse {
        ResponsesResponse(
            id: responseID,
            created_at: createdAt,
            status: .in_progress,
            model: model,
            output: []
        )
    }

    /// Build a completed response whose single assistant message carries the
    /// given final text. Used for the `response.completed` SSE event.
    public static func toCompletedObject(
        responseID: String,
        model: String,
        text: String,
        inputTokens: Int?,
        outputTokens: Int?,
        outputItems: [ResponsesOutputItem]? = nil,
        createdAt: Int = Int(Date().timeIntervalSince1970),
        diagnostics: inout Diagnostics
    ) -> ResponsesResponse {
        let messageID = newID(prefix: "msg_afm_")
        let message = ResponsesOutputItem.assistantMessage(id: messageID, text: text)
        let usage = makeUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            text: text,
            diagnostics: &diagnostics
        )
        return ResponsesResponse(
            id: responseID,
            created_at: createdAt,
            status: .completed,
            model: model,
            output: outputItems ?? [message],
            usage: usage
        )
    }

    /// Build a failed response object wrapping a bridge error.
    public static func toFailedObject(
        responseID: String,
        model: String,
        error: BridgeError,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) -> ResponsesResponse {
        ResponsesResponse(
            id: responseID,
            created_at: createdAt,
            status: .failed,
            model: model,
            output: [],
            usage: ResponsesUsage(input_tokens: 0, output_tokens: 0),
            error: error.errorObject
        )
    }

    // MARK: - Usage

    /// Produce a `ResponsesUsage`. When exact output token counts are missing,
    /// estimate from UTF-8 byte length and flag `diagnostics.estimatedUsage`.
    private static func makeUsage(
        inputTokens: Int?,
        outputTokens: Int?,
        text: String,
        diagnostics: inout Diagnostics
    ) -> ResponsesUsage? {
        let inTok = inputTokens ?? estimateTokens(text: nil)
        let outTok: Int
        if let o = outputTokens {
            outTok = o
        } else {
            outTok = estimateTokens(text: text)
            diagnostics.estimatedUsage = true
        }
        if inputTokens == nil {
            diagnostics.estimatedUsage = true
        }
        return ResponsesUsage(input_tokens: inTok, output_tokens: outTok)
    }

    /// Rough token estimate: ~1 token per 4 UTF-8 bytes (lower bound 1).
    public static func estimateTokens(text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        let bytes = text.utf8.count
        return max(1, bytes / 4)
    }
}

// MARK: - ID generation

/// Generates OpenAI-flavored IDs with the given prefix and a UUID with dashes
/// removed and lowercased.
public func newID(prefix: String) -> String {
    let uuid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return "\(prefix)\(uuid)"
}
