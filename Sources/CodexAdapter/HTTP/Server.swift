import Foundation
import BridgeHTTP
import Hummingbird
import HummingbirdCore
import NIOCore
import HTTPTypes
import Logging

/// Shared JSON encoder for all Responses API output.
let bridgeEncoder = BridgeJSON.encoder

/// Encode a value to a `ByteBuffer` with the shared encoder.
func encodeBuffer<T: Encodable>(_ value: T) throws -> ByteBuffer {
    try BridgeJSON.buffer(value)
}

/// Encode a value to a UTF-8 string with the shared encoder.
func encodeString<T: Encodable>(_ value: T) throws -> String {
    let data = try bridgeEncoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - BridgeError -> HTTP Response

/// Conformance that lets handlers `throw` a `BridgeError` and get an
/// OpenAI-shaped JSON error response with the right status code. The error
/// type itself lives in the OpenAI layer and is framework-agnostic; only this
/// conformance depends on Hummingbird.
extension BridgeError: HTTPResponseError {
    public var status: HTTPResponse.Status {
        HTTPResponse.Status(code: Int(self.httpStatus), reasonPhrase: "")
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        let body = try encodeBuffer(self.envelope)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(status: status, headers: headers, body: .init(byteBuffer: body))
    }
}

// MARK: - Server bootstrap

/// Builds and runs the Hummingbird application. Binds to 127.0.0.1 only.
public struct BridgeServer: Sendable {
    private let services: BridgeServices

    public init(services: BridgeServices) {
        self.services = services
    }

    /// Run the HTTP server until interrupted (SIGINT/SIGTERM).
    public func run() async throws {
        let router = Routes.build(services: services)
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(services.config.host, port: services.config.port),
                serverName: "codex-afm-bridge"
            ),
            logger: services.logger
        )
        services.logger.info(
            "codex-afm-bridge listening on http://\(services.config.host):\(services.config.port)"
        )
        try await app.runService()
    }
}
