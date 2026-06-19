import Foundation
import BridgeHTTP
import Hummingbird
import HummingbirdCore
import HTTPTypes

/// Middleware that enforces `Authorization: Bearer <AFM_BRIDGE_API_KEY>` on
/// every request. Returns an OpenAI-shaped 401 error on mismatch.
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    private let expectedToken: String

    public init(expectedToken: String) {
        self.expectedToken = expectedToken
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Health endpoint is unauthenticated so process managers can probe it.
        if request.uri.path == "/health" || request.uri.path == "/health/" {
            return try await next(request, context)
        }

        guard !expectedToken.isEmpty,
              BridgeAuthorization.bearerToken(in: request.headers) == expectedToken else {
            throw BridgeError.unauthorized
        }
        return try await next(request, context)
    }
}
