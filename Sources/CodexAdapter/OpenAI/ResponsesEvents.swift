import Foundation

// MARK: - SSE event envelopes

/// One Server-Sent Event payload. Each event has a `type` matching the event
/// name, plus the fields required by the Responses API streaming spec.
public enum ResponsesEvent: Sendable {
    case responseCreated(ResponsesResponse)
    case responseInProgress(ResponsesResponse)
    case responseOutputItemAdded(outputIndex: Int, item: ResponsesOutputItem)
    case responseContentPartAdded(outputIndex: Int, contentIndex: Int, part: ResponsesOutputContent)
    case responseOutputTextDelta(outputIndex: Int, contentIndex: Int, delta: String)
    case responseOutputTextDone(outputIndex: Int, contentIndex: Int, text: String)
    case responseOutputItemDone(outputIndex: Int, item: ResponsesOutputItem)
    case responseCompleted(ResponsesResponse, endTurn: Bool)
    case responseFailed(ResponsesResponse)
    case error(ResponsesErrorObject)

    /// The SSE `event:` name.
    public var eventName: String {
        switch self {
        case .responseCreated: return "response.created"
        case .responseInProgress: return "response.in_progress"
        case .responseOutputItemAdded: return "response.output_item.added"
        case .responseContentPartAdded: return "response.content_part.added"
        case .responseOutputTextDelta: return "response.output_text.delta"
        case .responseOutputTextDone: return "response.output_text.done"
        case .responseOutputItemDone: return "response.output_item.done"
        case .responseCompleted: return "response.completed"
        case .responseFailed: return "response.failed"
        case .error: return "error"
        }
    }

    /// JSON-encoded `data:` payload.
    public func data(encoder: JSONEncoder) throws -> String {
        let value: Encodable
        switch self {
        case .responseCreated(let r),
             .responseInProgress(let r),
             .responseFailed(let r):
            value = EventPayload.response(EventPayload.Response(type: eventName, response: r))
        case .responseCompleted(let r, let endTurn):
            value = EventPayload.responseCompleted(EventPayload.ResponseCompleted(
                type: eventName, response: EventPayload.CompletedResponse(
                    id: r.id, status: r.status, usage: r.usage, end_turn: endTurn
                )
            ))
        case .responseOutputItemAdded(let idx, let item):
            value = EventPayload.outputItemAdded(EventPayload.OutputItemAdded(
                type: eventName, output_index: idx, item: item))
        case .responseOutputItemDone(let idx, let item):
            value = EventPayload.outputItemDone(EventPayload.OutputItemDone(
                type: eventName, output_index: idx, item: item))
        case .responseContentPartAdded(let oi, let ci, let part):
            value = EventPayload.contentPartAdded(EventPayload.ContentPartAdded(
                type: eventName, output_index: oi, content_index: ci, part: part))
        case .responseOutputTextDelta(let oi, let ci, let delta):
            value = EventPayload.textDelta(EventPayload.TextDelta(
                type: eventName, output_index: oi, content_index: ci, delta: delta))
        case .responseOutputTextDone(let oi, let ci, let text):
            value = EventPayload.textDone(EventPayload.TextDone(
                type: eventName, output_index: oi, content_index: ci, text: text))
        case .error(let err):
            value = EventPayload.error(EventPayload.Error(type: "error", error: err))
        }
        let data = try value.encode(encoder)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Codable payload wrappers

private enum EventPayload {
    struct Response: Codable {
        let type: String
        let response: ResponsesResponse
    }
    static func response(_ r: Response) -> Encodable { r }

    struct ResponseCompleted: Codable {
        let type: String
        let response: CompletedResponse
    }
    struct CompletedResponse: Codable {
        let id: String
        let status: ResponsesStatus
        let usage: ResponsesUsage?
        let end_turn: Bool
    }
    static func responseCompleted(_ r: ResponseCompleted) -> Encodable { r }

    struct OutputItemAdded: Codable {
        let type: String
        let output_index: Int
        let item: ResponsesOutputItem
    }
    static func outputItemAdded(_ p: OutputItemAdded) -> Encodable { p }

    struct OutputItemDone: Codable {
        let type: String
        let output_index: Int
        let item: ResponsesOutputItem
    }
    static func outputItemDone(_ p: OutputItemDone) -> Encodable { p }

    struct ContentPartAdded: Codable {
        let type: String
        let output_index: Int
        let content_index: Int
        let part: ResponsesOutputContent
    }
    static func contentPartAdded(_ p: ContentPartAdded) -> Encodable { p }

    struct TextDelta: Codable {
        let type: String
        let output_index: Int
        let content_index: Int
        let delta: String
    }
    static func textDelta(_ p: TextDelta) -> Encodable { p }

    struct TextDone: Codable {
        let type: String
        let output_index: Int
        let content_index: Int
        let text: String
    }
    static func textDone(_ p: TextDone) -> Encodable { p }

    struct Error: Codable {
        let type: String
        let error: ResponsesErrorObject
    }
    static func error(_ p: Error) -> Encodable { p }
}

// MARK: - Convenience: encode any Encodable

private extension Encodable {
    func encode(_ encoder: JSONEncoder) throws -> Data {
        try encoder.encode(AnyEncodable(self))
    }
}

/// Type-erased codable wrapper so each payload case can go through one encoder.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self._encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

