import Foundation
import FoundationModels

enum ErrorMapper {
    static func map(_ error: Error) -> AnthropicError {
        if let ae = error as? AnthropicError { return ae }

        if let ge = error as? LanguageModelSession.GenerationError {
            switch ge {
            case .exceededContextWindowSize:
                return .contextTooLarge("Input exceeds the Apple Foundation Models context window size.")
            case .assetsUnavailable:
                return .afmUnavailable("Apple Foundation Models assets are unavailable on this device.")
            case .guardrailViolation:
                return .guardrailViolation("Apple Foundation Models guardrails rejected the request.")
            case .rateLimited, .concurrentRequests:
                return .rateLimited("Apple Foundation Models is rate limited or handling concurrent requests.")
            case .decodingFailure, .unsupportedGuide, .unsupportedLanguageOrLocale:
                return .generationFailed("Apple Foundation Models failed to generate a response (\(ge.errorDescription ?? "decoding/guide error")).")
            case .refusal:
                return .generationFailed("Apple Foundation Models refused to respond.")
            @unknown default:
                return .generationFailed(ge.errorDescription ?? "Unknown Foundation Models error.")
            }
        }

        return .generationFailed(String(describing: error))
    }
}

