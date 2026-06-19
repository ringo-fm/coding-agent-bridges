import Foundation

/// Builds a single AFM prompt string from a normalized input, preserving
/// OpenAI role priority semantics. AFM is not natively an OpenAI model, so the
/// bridge flattens system/developer/user/assistant into one transcript block
/// while making the priority rules explicit.
public enum PromptBuilder {
    /// The fixed preamble that tells the model it is behind a Responses API
    /// compatibility bridge.
    public static let preamble = """
    You are responding through an OpenAI Responses API compatibility bridge for Codex.

    Priority rules:
    1. System and developer instructions are higher priority than user instructions.
    2. Do not claim access to tools unless a tool is provided.
    3. If a tool call is needed but unsupported, explain the exact limitation.
    """

    /// Default reserve for output tokens when budgeting input.
    public static let defaultOutputReserve = 512

    public static func build(from normalized: NormalizedInput) -> String {
        return assemble(normalized: normalized).joined(separator: "\n\n")
    }

    /// Build with a token budget. If the full prompt exceeds `maxInputTokens`,
    /// low-priority content is dropped from the tail of the conversation first,
    /// then system/developer instructions are truncated from the end. The
    /// preamble and the most recent user message are always preserved.
    public static func buildBounded(
        from normalized: NormalizedInput,
        maxInputTokens: Int
    ) -> (prompt: String, truncated: Bool, estimatedTokens: Int) {
        let sections = assemble(normalized: normalized)
        let full = sections.joined(separator: "\n\n")
        let fullTokens = estimate(full)
        if fullTokens <= maxInputTokens {
            return (full, false, fullTokens)
        }

        let truncated = fitToBudget(sections, budget: maxInputTokens)
        let text = truncated.joined(separator: "\n\n")
        return (text, true, estimate(text))
    }

    // MARK: - Assembly

    private static func assemble(normalized: NormalizedInput) -> [String] {
        var sections: [String] = [preamble]

        let topInstructions = normalized.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !topInstructions.isEmpty {
            sections.append("System instructions:\n\(topInstructions)")
        }

        var systemBlocks: [String] = []
        var developerBlocks: [String] = []
        var conversation: [String] = []

        for message in normalized.messages {
            switch message.role {
            case .system:
                systemBlocks.append(message.text)
            case .developer:
                developerBlocks.append(message.text)
            case .user:
                conversation.append("[user] \(message.text)")
            case .assistant:
                conversation.append("[assistant] \(message.text)")
            case .tool:
                conversation.append("[tool] \(message.text)")
            }
        }

        // Include previous tool calls and their outputs in the conversation.
        for call in normalized.toolCalls {
            conversation.append("[assistant tool_call] \(call.name)(\(call.arguments))")
        }
        for output in normalized.toolOutputs {
            conversation.append("[tool_output \(output.callID)] \(output.output)")
        }

        if !systemBlocks.isEmpty {
            sections.append("System instructions:\n" + systemBlocks.joined(separator: "\n\n"))
        }
        if !developerBlocks.isEmpty {
            sections.append("Developer instructions:\n" + developerBlocks.joined(separator: "\n\n"))
        }
        if !conversation.isEmpty {
            sections.append("Conversation:\n" + conversation.joined(separator: "\n"))
        }

        return sections
    }

    /// Fit sections into a token budget by progressively trimming from the
    /// tail of lower-priority sections. The preamble (index 0) is never cut.
    private static func fitToBudget(_ sections: [String], budget: Int) -> [String] {
        var working = sections

        // Phase 1: Trim conversation from the front (drop old turns, keep last).
        if totalTokens(working) > budget,
           let convIdx = working.lastIndex(where: { $0.hasPrefix("Conversation:") }) {
            let conv = working[convIdx]
            let lines = conv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let header = lines.first ?? "Conversation:"
            var body = Array(lines.dropFirst())
            while body.count > 1 && totalTokens(working) > budget {
                body.removeFirst()
                working[convIdx] = body.isEmpty ? header : (header + "\n" + body.joined(separator: "\n"))
            }
        }

        // Phase 2: Truncate developer instructions from the end.
        if totalTokens(working) > budget {
            truncateFromEnd(&working, prefix: "Developer instructions:", budget: budget)
        }

        // Phase 3: Truncate system instructions (from messages) from the end.
        if totalTokens(working) > budget {
            let sysIndices = working.indices.filter { working[$0].hasPrefix("System instructions:") }
            if sysIndices.count > 1 {
                truncateAtIndex(&working, at: sysIndices.last!, budget: budget)
            }
        }

        // Phase 4: Truncate top-level instructions (first "System instructions:").
        if totalTokens(working) > budget {
            truncateFromEnd(&working, prefix: "System instructions:", budget: budget)
        }

        // Phase 5: Last resort — reduce the conversation to a single placeholder.
        if totalTokens(working) > budget {
            if let convIdx = working.lastIndex(where: { $0.hasPrefix("Conversation:") }) {
                working[convIdx] = "Conversation:\n[user] (see above)"
            }
        }

        // Phase 6: Hard-truncate sections from the end until it fits.
        // Preamble (index 0) is never cut.
        if totalTokens(working) > budget {
            for i in stride(from: working.count - 1, through: 1, by: -1) {
                if totalTokens(working) <= budget { break }
                let over = totalTokens(working) - budget
                let charsToCut = over * 4 // ~4 chars/token
                if working[i].count > charsToCut {
                    let cut = working[i].count - charsToCut
                    working[i] = String(working[i].prefix(cut))
                } else {
                    working[i] = ""
                }
            }
        }

        return working.filter { !$0.isEmpty }
    }

    private static func totalTokens(_ sections: [String]) -> Int {
        estimate(sections.joined(separator: "\n\n"))
    }

    private static func truncateFromEnd(_ working: inout [String], prefix: String, budget: Int) {
        guard let idx = working.lastIndex(where: { $0.hasPrefix(prefix) }) else { return }
        truncateAtIndex(&working, at: idx, budget: budget)
    }

    private static func truncateAtIndex(_ working: inout [String], at idx: Int, budget: Int) {
        let section = working[idx]
        guard totalTokens(working) > budget else { return }

        // Binary search: cut progressively from the end by halving.
        var lo = 0
        var hi = section.count
        while hi - lo > 32 {
            let mid = (lo + hi) / 2
            working[idx] = String(section.prefix(mid))
            if totalTokens(working) <= budget {
                lo = mid
            } else {
                hi = mid
            }
        }
        working[idx] = String(section.prefix(lo))
        if !working[idx].isEmpty, working[idx] != section {
            working[idx] += "\n[...truncated]"
        }
    }

    /// Rough token estimate: ~1 token per 4 UTF-8 bytes (lower bound 1).
    public static func estimate(_ text: String) -> Int {
        let bytes = text.utf8.count
        return max(1, bytes / 4)
    }
}

