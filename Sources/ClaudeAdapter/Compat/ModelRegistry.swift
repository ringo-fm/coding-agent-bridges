import Foundation

enum ModelRegistry {
    static let primaryModel = "claude-afm-local"

    static func resolve(_ requested: String) -> String? {
        if requested == primaryModel { return primaryModel }
        if requested.hasPrefix("claude-afm") { return primaryModel }
        if requested.hasPrefix("claude-3-5-haiku") { return primaryModel }
        if requested.hasPrefix("claude-3-5-sonnet") { return primaryModel }
        if requested.hasPrefix("claude-3-7") { return primaryModel }
        if requested.hasPrefix("claude-3-opus") { return primaryModel }
        if requested.hasPrefix("claude-sonnet") { return primaryModel }
        if requested.hasPrefix("claude-haiku") { return primaryModel }
        if requested.hasPrefix("claude-opus") { return primaryModel }
        return nil
    }

    static func isSupported(_ model: String) -> Bool { resolve(model) != nil }
}

