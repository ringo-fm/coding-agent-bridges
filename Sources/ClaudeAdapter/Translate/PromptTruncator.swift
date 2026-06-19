import Foundation

enum PromptTruncator {
    static let maxSystemChars = 1500
    static let maxToolPromptChars = 3000
    static let maxConversationChars = 4000
    static let hardInputChars = 200_000

    static func isTooLarge(instructions: String, conversation: String) -> Bool {
        instructions.count + conversation.count > hardInputChars
    }

    static func truncateSystem(_ system: String) -> String {
        if system.count <= maxSystemChars { return system }
        let truncated = String(system.prefix(maxSystemChars))
        return truncated + "\n\n[... system prompt truncated by claude-afm-bridge to fit AFM context window ...]"
    }

    static func truncateConversation(_ conversation: String) -> String {
        if conversation.count <= maxConversationChars { return conversation }
        let truncated = String(conversation.suffix(maxConversationChars))
        return "[... earlier conversation truncated by claude-afm-bridge ...]\n" + truncated
    }

    static func truncateToolPrompt(_ toolPrompt: String) -> String {
        if toolPrompt.count <= maxToolPromptChars { return toolPrompt }
        return String(toolPrompt.prefix(maxToolPromptChars)) + "\n[... additional tools truncated ...]"
    }

    static func truncate(instructions: String, conversation: String) -> (instructions: String, conversation: String, truncated: Bool) {
        var instr = instructions
        var conv = conversation
        var didTruncate = false

        let totalBudget = maxSystemChars + maxToolPromptChars + maxConversationChars
        if instr.count + conv.count > totalBudget {
            didTruncate = true
            instr = truncateSystem(instr)
            conv = truncateConversation(conv)
        }

        return (instr, conv, didTruncate)
    }

    static func buildTruncatedInstructions(systemText: String?, tools: [ToolDefinition]?) -> (instructions: String, truncated: Bool) {
        let truncatedSystem = systemText.map { truncateSystem($0) } ?? nil
        var instr = TranscriptBuilder.header
        if let sys = truncatedSystem, !sys.isEmpty {
            instr += "\n\nSystem instructions:\n" + sys
        }
        let didTruncate = truncatedSystem != systemText

        if let tools, !tools.isEmpty {
            let toolPrompt = ToolMapper.buildToolPrompt(tools: tools)
            let truncatedToolPrompt = truncateToolPrompt(toolPrompt)
            instr += "\n\n" + truncatedToolPrompt
            if truncatedToolPrompt != toolPrompt { return (instr, true) }
        }

        return (instr, didTruncate)
    }
}

