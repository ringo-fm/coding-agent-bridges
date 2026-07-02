import Foundation
import BridgeHTTP
import NIOCore

enum SSEWriter {
    static func event<T: Encodable>(_ type: String, payload: T, allocator: ByteBufferAllocator) -> ByteBuffer {
        (try? SSEFrame.make(event: type, payload: payload, allocator: allocator)) ?? allocator.buffer(capacity: 0)
    }

    static func keepalive(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buf = allocator.buffer(capacity: 16)
        buf.writeString(": keepalive\n\n")
        return buf
    }
}
