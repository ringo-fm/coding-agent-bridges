import Foundation
import FoundationModels

enum TokenCounter {
    static func heuristic(_ s: String) -> Int {
        let bytes = s.utf8.count
        let chars = s.count
        let byBytes = max(1, bytes / 3)
        let byChars = max(1, chars / 3)
        return max(byBytes, byChars)
    }

    static func countInput(model: SystemLanguageModel, system: String, conversation: String) async -> Int {
        let sysTokens = await countText(model: model, text: system, asInstructions: true)
        let convTokens = await countText(model: model, text: conversation, asInstructions: false)
        return sysTokens + convTokens
    }

    static func countOutput(model: SystemLanguageModel, text: String) async -> Int {
        if text.isEmpty { return 0 }
        return await countText(model: model, text: text, asInstructions: false)
    }

    private static func countText(model: SystemLanguageModel, text: String, asInstructions: Bool) async -> Int {
        if text.isEmpty { return 0 }
        if #available(macOS 26.4, *) {
            if asInstructions {
                if let n = try? await model.tokenCount(for: Instructions(text)) { return n }
            } else {
                if let n = try? await model.tokenCount(for: text) { return n }
            }
        }
        return heuristic(text)
    }
}

