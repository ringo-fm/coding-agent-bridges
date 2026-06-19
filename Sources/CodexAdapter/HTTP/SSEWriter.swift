import Foundation
import HummingbirdCore
import NIOCore

/// Writes Server-Sent Events to an HTTP response body. Each event is framed as
/// `event: <name>\ndata: <json>\n\n`. The caller is responsible for computing
/// deltas from AFM's cumulative snapshots; this type only handles framing.
public struct SSEWriter: Sendable {
    public let allocator: ByteBufferAllocator

    public init(allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.allocator = allocator
    }

    /// Write one Responses event.
    public func write(
        _ event: ResponsesEvent,
        to writer: inout any ResponseBodyWriter
    ) async throws {
        let payload = try event.data(encoder: bridgeEncoder)
        try await writeRaw(event: event.eventName, data: payload, to: &writer)
    }

    /// Write a raw event with a pre-formatted data string.
    public func writeRaw(
        event: String,
        data: String,
        to writer: inout any ResponseBodyWriter
    ) async throws {
        var buffer = allocator.buffer(capacity: data.utf8.count + event.utf8.count + 16)
        buffer.writeString("event: \(event)\n")
        buffer.writeString("data: \(data)\n\n")
        try await writer.write(buffer)
    }

    /// Write a comment line (used as a keepalive heartbeat).
    public func writeComment(
        _ comment: String,
        to writer: inout any ResponseBodyWriter
    ) async throws {
        var buffer = allocator.buffer(capacity: comment.utf8.count + 2)
        buffer.writeString(": \(comment)\n\n")
        try await writer.write(buffer)
    }
}

