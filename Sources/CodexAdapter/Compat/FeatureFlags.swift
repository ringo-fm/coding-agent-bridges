import Foundation

/// Feature flags controlling which Responses API capabilities the bridge
/// advertises and honors. Driven by the compatibility profile but can also
/// be overridden via environment variables for experimentation.
public struct FeatureFlags: Sendable, Equatable {
    public var textGeneration: Bool
    public var streaming: Bool
    public var functionCall: Bool
    public var shellCall: Bool
    public var applyPatchCall: Bool
    public var imageInput: Bool
    public var fileInput: Bool
    public var reasoningItems: Bool
    public var usageEstimation: Bool

    public init(
        textGeneration: Bool = true,
        streaming: Bool = true,
        functionCall: Bool = false,
        shellCall: Bool = false,
        applyPatchCall: Bool = false,
        imageInput: Bool = false,
        fileInput: Bool = false,
        reasoningItems: Bool = false,
        usageEstimation: Bool = true
    ) {
        self.textGeneration = textGeneration
        self.streaming = streaming
        self.functionCall = functionCall
        self.shellCall = shellCall
        self.applyPatchCall = applyPatchCall
        self.imageInput = imageInput
        self.fileInput = fileInput
        self.reasoningItems = reasoningItems
        self.usageEstimation = usageEstimation
    }

    /// v0: text-only, no tools, no images, estimated usage.
    public static let codexMinimal = FeatureFlags()

    /// v1: adds function-call support (read-only tools).
    public static let codexTools = FeatureFlags(
        functionCall: true,
        shellCall: true,
        applyPatchCall: true
    )

    /// Load overrides from environment variables. Any `AFM_BRIDGE_FEATURE_*`
    /// variable set to "1" or "true" enables that feature; "0" or "false"
    /// disables it.
    public static func loadOverrides(base: FeatureFlags = .codexMinimal) -> FeatureFlags {
        loadOverrides(from: ProcessInfo.processInfo.environment, base: base)
    }

    /// Load overrides from an explicit environment dictionary. This keeps the
    /// production env loader simple while making profile behavior deterministic
    /// in tests.
    public static func loadOverrides(
        from env: [String: String],
        base: FeatureFlags = .codexMinimal
    ) -> FeatureFlags {
        var flags = base

        func read(_ key: String) -> Bool? {
            guard let v = env[key] else { return nil }
            return v == "1" || v.lowercased() == "true"
        }

        if let v = read("AFM_BRIDGE_FEATURE_FUNCTION_CALL") { flags.functionCall = v }
        if let v = read("AFM_BRIDGE_FEATURE_SHELL_CALL") { flags.shellCall = v }
        if let v = read("AFM_BRIDGE_FEATURE_APPLY_PATCH") { flags.applyPatchCall = v }
        if let v = read("AFM_BRIDGE_FEATURE_IMAGE_INPUT") { flags.imageInput = v }
        if let v = read("AFM_BRIDGE_FEATURE_FILE_INPUT") { flags.fileInput = v }
        if let v = read("AFM_BRIDGE_FEATURE_STREAMING") { flags.streaming = v }
        if let v = read("AFM_BRIDGE_FEATURE_USAGE_ESTIMATION") { flags.usageEstimation = v }

        return flags
    }
}

