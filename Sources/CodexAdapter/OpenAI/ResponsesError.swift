import Foundation

// MARK: - Error codes

/// Stable error codes used in `ResponsesErrorObject.code` / `.type`.
public enum ResponsesErrorCode: String, Sendable {
    case afmUnavailable = "afm_unavailable"
    case unsupportedModel = "unsupported_model"
    case unsupportedInputType = "unsupported_input_type"
    case unsupportedToolType = "unsupported_tool_type"
    case unsupportedLanguageOrLocale = "unsupported_language_or_locale"
    case generationCancelled = "generation_cancelled"
    case generationFailed = "generation_failed"
    case contextTooLarge = "context_too_large"
    case unauthorized = "unauthorized"
    case invalidRequest = "invalid_request"
    case internalError = "internal_error"
}

// MARK: - Bridge errors

/// Errors raised by the bridge. Each carries a stable code and an HTTP status.
public enum BridgeError: Error, Sendable {
    case afmUnavailable(reason: String)
    case unsupportedModel(String)
    case unsupportedInputType(String)
    case unsupportedToolType(String)
    case unsupportedLanguageOrLocale(String)
    case generationCancelled
    case generationFailed(String)
    case contextTooLarge(inputTokens: Int, limit: Int)
    case unauthorized
    case invalidRequest(String)
    case internalError(String)

    public var code: ResponsesErrorCode {
        switch self {
        case .afmUnavailable: return .afmUnavailable
        case .unsupportedModel: return .unsupportedModel
        case .unsupportedInputType: return .unsupportedInputType
        case .unsupportedToolType: return .unsupportedToolType
        case .unsupportedLanguageOrLocale: return .unsupportedLanguageOrLocale
        case .generationCancelled: return .generationCancelled
        case .generationFailed: return .generationFailed
        case .contextTooLarge: return .contextTooLarge
        case .unauthorized: return .unauthorized
        case .invalidRequest: return .invalidRequest
        case .internalError: return .internalError
        }
    }

    public var httpStatus: Int {
        switch self {
        case .afmUnavailable: return 503
        case .unsupportedModel: return 400
        case .unsupportedInputType: return 400
        case .unsupportedToolType: return 400
        case .unsupportedLanguageOrLocale: return 400
        case .generationCancelled: return 499
        case .generationFailed: return 500
        case .contextTooLarge: return 413
        case .unauthorized: return 401
        case .invalidRequest: return 400
        case .internalError: return 500
        }
    }

    public var message: String {
        switch self {
        case .afmUnavailable(let reason):
            return "Apple Foundation Models are not available on this device: \(reason)."
        case .unsupportedModel(let m):
            return "Requested model '\(m)' is not supported. Use 'apple-foundation-local'."
        case .unsupportedInputType(let t):
            return "Input type '\(t)' is not supported in this compatibility profile."
        case .unsupportedToolType(let t):
            return "Tool type '\(t)' is not supported in this compatibility profile."
        case .unsupportedLanguageOrLocale(let d):
            return "Apple Foundation Models rejected the language or locale: \(d)."
        case .generationCancelled:
            return "Generation was cancelled."
        case .generationFailed(let d):
            return "Apple Foundation Models generation failed: \(d)."
        case .contextTooLarge(let input, let limit):
            if input > 0 {
                return "Input exceeded supported context size (input ~\(input) tokens, limit \(limit))."
            } else {
                return "Input exceeded supported context size (limit \(limit) tokens). The prompt was truncated but still exceeded the model's context window."
            }
        case .unauthorized:
            return "Missing or invalid Authorization header. Expected 'Bearer <AFM_BRIDGE_API_KEY>'."
        case .invalidRequest(let d):
            return "Invalid request: \(d)"
        case .internalError(let d):
            return "Internal bridge error: \(d)"
        }
    }

    public var errorObject: ResponsesErrorObject {
        ResponsesErrorObject(
            message: message,
            type: code.rawValue,
            param: nil,
            code: code.rawValue
        )
    }

    public var envelope: ResponsesErrorEnvelope {
        ResponsesErrorEnvelope(error: errorObject)
    }
}

