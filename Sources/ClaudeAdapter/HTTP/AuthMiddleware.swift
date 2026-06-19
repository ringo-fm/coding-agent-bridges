import Hummingbird
import HTTPTypes
import BridgeHTTP

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let config: BridgeConfig

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if !config.requiresAuth || request.uri.path == "/health" {
            return try await next(request, context)
        }
        if BridgeAuthorization.matches(headers: request.headers, expectedToken: config.authToken) {
            return try await next(request, context)
        }
        return anthropicErrorResponse(.unauthorized("Missing or invalid API key. Provide x-api-key or Authorization: Bearer matching the configured token."))
    }
}
