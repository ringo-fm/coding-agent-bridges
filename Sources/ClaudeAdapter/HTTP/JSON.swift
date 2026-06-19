import Foundation
import BridgeHTTP
import Hummingbird
import HTTPTypes
import NIOCore

func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok,
    extraHeaders: [(String, String)] = []
) -> Response {
    let data = (try? BridgeJSON.encoder.encode(value)) ?? Data()
    var headers: HTTPFields = [.contentType: "application/json"]
    for (name, value) in extraHeaders {
        if let n = HTTPField.Name(name) {
            headers.append(HTTPField(name: n, value: value))
        }
    }
    return Response(status: status, headers: headers, body: .init { writer in
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await writer.write(buffer)
        try await writer.finish(nil)
    })
}

func anthropicErrorResponse(_ error: AnthropicError) -> Response {
    let envelope = AnthropicErrorEnvelope(errorType: error.errorType, message: error.message)
    return jsonResponse(envelope, status: error.httpStatus, extraHeaders: [("x-afm-error-code", error.code.rawValue)])
}
