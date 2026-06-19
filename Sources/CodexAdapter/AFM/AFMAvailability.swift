import Foundation
import FoundationModels

/// A normalized availability result for Apple Foundation Models.
public enum AFMAvailability: Sendable, Equatable {
    case available
    case unavailable(AFMUnavailableReason)

    public var isAvailable: Bool {
        self == .available
    }
}

public enum AFMUnavailableReason: String, Sendable, Equatable {
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unknown

    public var message: String {
        switch self {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled on this device."
        case .deviceNotEligible:
            return "This device is not eligible for Apple Foundation Models."
        case .modelNotReady:
            return "The on-device model is not ready yet. Try again shortly."
        case .unknown:
            return "Apple Foundation Models are unavailable for an unknown reason."
        }
    }
}

/// Wraps the live `SystemLanguageModel.availability` query so the rest of the
/// bridge does not depend on FoundationModels directly.
public enum AFMAvailabilityProbe {
    public static func current() -> AFMAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable(_):
            return .unavailable(.unknown)
        @unknown default:
            return .unavailable(.unknown)
        }
    }

    /// Bridges an availability result to a `BridgeError` when not available.
    public static func requireAvailable() throws {
        let av = current()
        guard av.isAvailable else {
            if case .unavailable(let reason) = av {
                throw BridgeError.afmUnavailable(reason: reason.message)
            }
            throw BridgeError.afmUnavailable(reason: "unknown")
        }
    }
}

