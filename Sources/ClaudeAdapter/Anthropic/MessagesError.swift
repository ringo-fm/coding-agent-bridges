import Foundation
import Hummingbird

struct AnthropicErrorEnvelope: Codable {
    let type: String
    let error: Body

    struct Body: Codable {
        let type: String
        let message: String
    }

    init(errorType: String, message: String) {
        self.type = "error"
        self.error = Body(type: errorType, message: message)
    }
}

enum AnthropicErrorCode: String, Sendable {
    case afmUnavailable = "afm_unavailable"
    case unsupportedInputType = "unsupported_input_type"
    case unsupportedToolType = "unsupported_tool_type"
    case contextTooLarge = "context_too_large"
    case unsupportedModel = "unsupported_model"
    case generationFailed = "generation_failed"
    case generationCancelled = "generation_cancelled"
    case guardrailViolation = "guardrail_violation"
    case rateLimited = "rate_limited"
    case authenticationError = "authentication_error"
}

struct AnthropicError: Error, Sendable {
    let httpStatus: HTTPResponse.Status
    let errorType: String
    let code: AnthropicErrorCode
    let message: String

    static let invalidRequest = "invalid_request_error"
    static let notFound = "not_found_error"
    static let apiError = "api_error"
    static let authentication = "authentication_error"

    init(_ status: HTTPResponse.Status, _ errorType: String, _ code: AnthropicErrorCode, _ message: String) {
        self.httpStatus = status
        self.errorType = errorType
        self.code = code
        self.message = message
    }

    static func afmUnavailable(_ m: String) -> AnthropicError { .init(.badRequest, invalidRequest, .afmUnavailable, m) }
    static func unsupportedModel(_ m: String) -> AnthropicError { .init(.notFound, notFound, .unsupportedModel, m) }
    static func contextTooLarge(_ m: String) -> AnthropicError { .init(.badRequest, invalidRequest, .contextTooLarge, m) }
    static func unsupportedInput(_ m: String) -> AnthropicError { .init(.badRequest, invalidRequest, .unsupportedInputType, m) }
    static func guardrailViolation(_ m: String) -> AnthropicError { .init(.badRequest, invalidRequest, .guardrailViolation, m) }
    static func generationFailed(_ m: String) -> AnthropicError { .init(.internalServerError, apiError, .generationFailed, m) }
    static func rateLimited(_ m: String) -> AnthropicError { .init(.internalServerError, apiError, .rateLimited, m) }
    static func unauthorized(_ m: String) -> AnthropicError { .init(.unauthorized, authentication, .authenticationError, m) }
    static func badRequest(_ m: String) -> AnthropicError { .init(.badRequest, invalidRequest, .unsupportedInputType, m) }
}

