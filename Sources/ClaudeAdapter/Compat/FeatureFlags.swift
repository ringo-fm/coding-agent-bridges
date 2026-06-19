import Foundation

struct FeatureFlags: Sendable {
    let toolUseGeneration: Bool
    let toolResultIngest: Bool
    let streaming: Bool
    let countTokens: Bool

    static let mvp = FeatureFlags(toolUseGeneration: false, toolResultIngest: true, streaming: true, countTokens: true)
    static let current = FeatureFlags(toolUseGeneration: true, toolResultIngest: true, streaming: true, countTokens: true)
}

