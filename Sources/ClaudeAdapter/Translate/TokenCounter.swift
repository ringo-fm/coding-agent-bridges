import Foundation
import FoundationModels

enum TokenCounter {
    static func heuristic(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return max(1, (s.utf8.count + 2) / 3)
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

