import Foundation
import HummingbirdCore
import HTTPTypes
import NIOCore

public enum BridgeJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    public static func buffer<T: Encodable>(_ value: T) throws -> ByteBuffer {
        ByteBuffer(data: try encoder.encode(value))
    }
}

public enum SSEFrame {
    public static func make<T: Encodable>(
        event: String,
        payload: T,
        allocator: ByteBufferAllocator = .init()
    ) throws -> ByteBuffer {
        let data = try BridgeJSON.encoder.encode(payload)
        var buffer = allocator.buffer(capacity: data.count + event.utf8.count + 16)
        buffer.writeString("event: \(event)\n")
        buffer.writeString("data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        return buffer
    }
}

public enum BridgeAuthorization {
    public static func bearerToken(in headers: HTTPFields) -> String? {
        guard let value = headers[.authorization] else { return nil }
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bearer" else { return nil }
        return String(pieces[1])
    }

    public static func matches(headers: HTTPFields, expectedToken: String?) -> Bool {
        guard let expectedToken else { return true }
        return bearerToken(in: headers) == expectedToken
            || headers[HTTPField.Name("x-api-key")!] == expectedToken
    }
}
