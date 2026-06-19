import Foundation

struct CompatibilityProfile: Sendable {
    let name: String
    let features: Features

    struct Features: Sendable {
        let messages: Bool
        let stream: Bool
        let countTokens: String
        let text: Bool
        let toolResultIngest: Bool
        let toolUseOutput: String
        let thinking: Bool
        let promptCaching: String
        let images: Bool
        let files: Bool
        let mcp: Bool
    }

    static let claudeCodeTools = CompatibilityProfile(
        name: "claude-code-tools",
        features: Features(
            messages: true,
            stream: true,
            countTokens: "native",
            text: true,
            toolResultIngest: true,
            toolUseOutput: "structured",
            thinking: false,
            promptCaching: "ignored",
            images: false,
            files: false,
            mcp: false
        )
    )

    static let current = claudeCodeTools
}

