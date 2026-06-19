import Foundation

/// How a field was handled by the bridge.
public enum FieldDisposition: String, Sendable, Equatable {
    case ignored        // field accepted but not acted upon
    case rejected       // field caused a hard error
    case estimated      // value was estimated rather than measured
    case truncated      // content was truncated to fit context
    case unsupported    // feature not available in current profile
}

/// A single diagnostic entry with structured classification.
public struct DiagnosticEntry: Sendable, Equatable {
    public let field: String
    public let disposition: FieldDisposition
    public let detail: String

    public init(field: String, disposition: FieldDisposition, detail: String = "") {
        self.field = field
        self.disposition = disposition
        self.detail = detail
    }
}

/// Per-request diagnostics. Records fields the bridge ignored, rejected,
/// estimated, or truncated so callers can tune the compatibility profile.
/// Not persisted; only surfaced in debug logs and (optionally) in response
/// headers.
public struct Diagnostics: Sendable {
    public var entries: [DiagnosticEntry]
    public var unsupportedInputTypes: [String]
    public var unsupportedToolTypes: [String]
    public var estimatedUsage: Bool
    public var promptTruncated: Bool

    public init(
        entries: [DiagnosticEntry] = [],
        unsupportedInputTypes: [String] = [],
        unsupportedToolTypes: [String] = [],
        estimatedUsage: Bool = false,
        promptTruncated: Bool = false
    ) {
        self.entries = entries
        self.unsupportedInputTypes = unsupportedInputTypes
        self.unsupportedToolTypes = unsupportedToolTypes
        self.estimatedUsage = estimatedUsage
        self.promptTruncated = promptTruncated
    }

    // MARK: - Backward-compatible accessors

    public var ignoredFields: [String] {
        entries.filter { $0.disposition == .ignored }.map(\.field)
    }

    public var rejectedFields: [String] {
        entries.filter { $0.disposition == .rejected }.map(\.field)
    }

    public var notes: [String] {
        entries.compactMap { entry in
            entry.detail.isEmpty ? nil : "\(entry.disposition.rawValue) \(entry.field): \(entry.detail)"
        }
    }

    // MARK: - Mutators

    public mutating func ignore(_ field: String, reason: String = "") {
        entries.append(DiagnosticEntry(field: field, disposition: .ignored, detail: reason))
    }

    public mutating func reject(_ field: String, reason: String = "") {
        entries.append(DiagnosticEntry(field: field, disposition: .rejected, detail: reason))
    }

    public mutating func markEstimated(_ field: String, detail: String = "") {
        entries.append(DiagnosticEntry(field: field, disposition: .estimated, detail: detail))
    }

    public mutating func markTruncated(_ field: String, detail: String = "") {
        entries.append(DiagnosticEntry(field: field, disposition: .truncated, detail: detail))
        promptTruncated = true
    }

    public mutating func unsupportedInput(_ type: String) {
        unsupportedInputTypes.append(type)
        entries.append(DiagnosticEntry(field: type, disposition: .unsupported, detail: "input type"))
    }

    public mutating func unsupportedTool(_ type: String) {
        unsupportedToolTypes.append(type)
        entries.append(DiagnosticEntry(field: type, disposition: .unsupported, detail: "tool type"))
    }

    public mutating func note(_ s: String) {
        entries.append(DiagnosticEntry(field: "note", disposition: .ignored, detail: s))
    }

    public var isEmpty: Bool {
        entries.isEmpty && unsupportedInputTypes.isEmpty
            && unsupportedToolTypes.isEmpty && !estimatedUsage && !promptTruncated
    }

    /// Compact summary for the x-afm-diagnostics header.
    public var summary: String {
        var bits: [String] = []
        let ignored = ignoredFields
        if !ignored.isEmpty {
            bits.append("ignored=" + ignored.joined(separator: ","))
        }
        if !unsupportedInputTypes.isEmpty {
            bits.append("unsupported_input=" + unsupportedInputTypes.joined(separator: ","))
        }
        if !unsupportedToolTypes.isEmpty {
            bits.append("unsupported_tool=" + unsupportedToolTypes.joined(separator: ","))
        }
        if estimatedUsage { bits.append("usage=estimated") }
        if promptTruncated { bits.append("prompt=truncated") }
        return bits.joined(separator: "; ")
    }
}

