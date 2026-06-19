import Foundation

public protocol ContextSummarizer: Sendable {
    func summarize(_ segments: [ContextSegment]) async throws -> ContextCapsule
}

public struct DeterministicContextSummarizer: ContextSummarizer {
    public init() {}

    public func summarize(_ segments: [ContextSegment]) async throws -> ContextCapsule {
        var constraints: [String] = []
        var decisions: [String] = []
        var files: [String] = []
        var completed: [String] = []
        var failures: [String] = []
        var pending: [String] = []

        for segment in segments {
            let lines = segment.text.split(separator: "\n").map(String.init)
            for line in lines {
                let lower = line.lowercased()
                if lower.contains("must") || lower.contains("required") || lower.contains("do not") || lower.contains("constraint") {
                    Self.appendUnique(Self.bounded(line), to: &constraints)
                }
                if lower.contains("decided") || lower.contains("decision") || lower.contains("use ") {
                    Self.appendUnique(Self.bounded(line), to: &decisions)
                }
                if lower.contains("failed") || lower.contains("error") || lower.contains("exception") {
                    Self.appendUnique(Self.bounded(line), to: &failures)
                }
                if lower.contains("todo") || lower.contains("pending") || lower.contains("next") {
                    Self.appendUnique(Self.bounded(line), to: &pending)
                }
                if lower.contains("completed") || lower.contains("done") || lower.contains("passed") {
                    Self.appendUnique(Self.bounded(line), to: &completed)
                }
                for token in line.split(whereSeparator: { $0.isWhitespace || ",:()[]{}<>\"'`".contains($0) }) {
                    let value = String(token)
                    if value.contains("/") || value.hasSuffix(".swift") || value.hasSuffix(".json") || value.hasSuffix(".md") {
                        Self.appendUnique(Self.bounded(value, limit: 180), to: &files)
                    }
                }
            }
        }

        let objective = segments.last(where: { $0.kind == .currentRequest })?.text
            ?? segments.last?.text
            ?? ""
        return ContextCapsule(
            objective: Self.bounded(objective, limit: 500),
            constraints: Array(constraints.prefix(12)),
            decisions: Array(decisions.prefix(12)),
            filesAndSymbols: Array(files.prefix(20)),
            completedActions: Array(completed.prefix(12)),
            failedAttempts: Array(failures.prefix(12)),
            pendingTasks: Array(pending.prefix(12)),
            sourceTurnIDs: segments.compactMap(\.sourceTurnID)
        )
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    private static func bounded(_ value: String, limit: Int = 300) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

public enum ContextCompaction {
    public static func addCapsuleIfNeeded(
        to segments: [ContextSegment],
        initialPlan: ContextPlan,
        conversationID: String,
        ledger: any ContextLedger,
        summarizer: any ContextSummarizer = DeterministicContextSummarizer()
    ) async throws -> [ContextSegment] {
        guard !initialPlan.omittedSegmentIDs.isEmpty else { return segments }
        let omitted = Set(initialPlan.omittedSegmentIDs)
        let sources = segments.filter { omitted.contains($0.id) }
        guard !sources.isEmpty else { return segments }

        let capsule = try await summarizer.summarize(sources)
        try await ledger.saveCapsule(capsule, for: conversationID)
        let rendered = capsule.rendered
        guard !rendered.isEmpty else { return segments }
        let summary = ContextSegment(
            id: "capsule-" + ConversationFingerprint.digest(rendered),
            kind: .summary,
            text: "Compacted context:\n" + rendered,
            metadata: ["compacted": "true"]
        )
        return segments + [summary]
    }
}
