import CryptoKit
import Foundation

public enum ContextSegmentKind: String, Codable, Sendable, CaseIterable {
    case currentRequest
    case unresolvedToolResult
    case requiredTool
    case recentConversation
    case instruction
    case olderConversation
    case retrievedSource
    case summary
}

public struct ContextSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ContextSegmentKind
    public let text: String
    public let sourceTurnID: String?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        kind: ContextSegmentKind,
        text: String,
        sourceTurnID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceTurnID = sourceTurnID
        self.metadata = metadata
    }

    public var estimatedTokens: Int {
        ContextPlanner.estimateTokens(text)
    }
}

public struct ContextCapsule: Codable, Sendable, Equatable {
    public var objective: String
    public var constraints: [String]
    public var decisions: [String]
    public var filesAndSymbols: [String]
    public var completedActions: [String]
    public var failedAttempts: [String]
    public var pendingTasks: [String]
    public var sourceTurnIDs: [String]

    public init(
        objective: String = "",
        constraints: [String] = [],
        decisions: [String] = [],
        filesAndSymbols: [String] = [],
        completedActions: [String] = [],
        failedAttempts: [String] = [],
        pendingTasks: [String] = [],
        sourceTurnIDs: [String] = []
    ) {
        self.objective = objective
        self.constraints = constraints
        self.decisions = decisions
        self.filesAndSymbols = filesAndSymbols
        self.completedActions = completedActions
        self.failedAttempts = failedAttempts
        self.pendingTasks = pendingTasks
        self.sourceTurnIDs = sourceTurnIDs
    }

    public var rendered: String {
        var sections: [String] = []
        if !objective.isEmpty { sections.append("Objective: \(objective)") }
        Self.append("Constraints", constraints, to: &sections)
        Self.append("Decisions", decisions, to: &sections)
        Self.append("Files and symbols", filesAndSymbols, to: &sections)
        Self.append("Completed", completedActions, to: &sections)
        Self.append("Failed attempts", failedAttempts, to: &sections)
        Self.append("Pending", pendingTasks, to: &sections)
        return sections.joined(separator: "\n")
    }

    private static func append(_ title: String, _ values: [String], to sections: inout [String]) {
        guard !values.isEmpty else { return }
        sections.append(title + ":\n" + values.map { "- \($0)" }.joined(separator: "\n"))
    }
}

public struct ContextPlan: Sendable, Equatable {
    public let segments: [ContextSegment]
    public let omittedSegmentIDs: [String]
    public let estimatedTokens: Int
    public let budget: Int
    public let truncated: Bool

    public init(
        segments: [ContextSegment],
        omittedSegmentIDs: [String],
        estimatedTokens: Int,
        budget: Int,
        truncated: Bool
    ) {
        self.segments = segments
        self.omittedSegmentIDs = omittedSegmentIDs
        self.estimatedTokens = estimatedTokens
        self.budget = budget
        self.truncated = truncated
    }

    public var prompt: String {
        segments.map(\.text).joined(separator: "\n\n")
    }
}

public enum ContextPlanner {
    public static func plan(segments: [ContextSegment], budget: Int) -> ContextPlan {
        let safeBudget = max(1, budget)
        let protectedKinds: Set<ContextSegmentKind> = [.instruction, .currentRequest]
        let protected = segments.enumerated()
            .filter { protectedKinds.contains($0.element.kind) }
            .sorted { lhs, rhs in
                let lp = priority(lhs.element.kind)
                let rp = priority(rhs.element.kind)
                return lp == rp ? lhs.offset < rhs.offset : lp > rp
            }
        let ranked = segments.enumerated().filter { !protectedKinds.contains($0.element.kind) }.sorted { lhs, rhs in
            let lp = priority(lhs.element.kind)
            let rp = priority(rhs.element.kind)
            if lp != rp { return lp > rp }
            return lhs.offset > rhs.offset
        }

        var selected: [(Int, ContextSegment)] = []
        var omitted: [String] = []
        var used = 0

        for (position, item) in protected.enumerated() {
            let remainingSegments = protected.count - position - 1
            let available = max(1, safeBudget - used - remainingSegments)
            let segment = item.element.estimatedTokens <= available
                ? item.element
                : bound(item.element, to: available)
            selected.append((item.offset, segment))
            used += segment.estimatedTokens
        }

        for (index, segment) in ranked {
            let cost = segment.estimatedTokens
            if used + cost <= safeBudget {
                selected.append((index, segment))
                used += cost
                continue
            }

            omitted.append(segment.id)
        }

        let ordered = selected.sorted { $0.0 < $1.0 }.map(\.1)
        return ContextPlan(
            segments: ordered,
            omittedSegmentIDs: omitted,
            estimatedTokens: used,
            budget: safeBudget,
            truncated: !omitted.isEmpty || ordered.contains { $0.metadata["truncated"] == "true" }
        )
    }

    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 3) / 4)
    }

    private static func priority(_ kind: ContextSegmentKind) -> Int {
        switch kind {
        case .instruction: 800
        case .currentRequest: 700
        case .unresolvedToolResult: 600
        case .requiredTool: 500
        case .retrievedSource: 450
        case .recentConversation: 400
        case .summary: 350
        case .olderConversation: 100
        }
    }

    private static func bound(_ segment: ContextSegment, to tokens: Int) -> ContextSegment {
        let marker = segment.kind == .instruction
            ? "[...instruction truncated...]\n"
            : "[...current request truncated...]\n"
        let byteBudget = max(1, tokens * 4)
        let includeMarker = byteBudget > marker.utf8.count + 8
        let contentBudget = max(1, byteBudget - (includeMarker ? marker.utf8.count : 0))
        let suffix = String(decoding: segment.text.utf8.suffix(contentBudget), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = segment.metadata
        metadata["truncated"] = "true"
        return ContextSegment(
            id: segment.id,
            kind: segment.kind,
            text: (includeMarker ? marker : "") + suffix,
            sourceTurnID: segment.sourceTurnID,
            metadata: metadata
        )
    }
}

public enum ConversationFingerprint {
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func conversationKey(
        protocolName: String,
        instructions: String,
        toolCatalog: String,
        turnHashes: [String]
    ) -> String {
        digest(([protocolName, digest(instructions), digest(toolCatalog)] + turnHashes).joined(separator: "\u{1f}"))
    }

    public static func isAppendOnly(previous: [String], current: [String]) -> Bool {
        current.count >= previous.count && Array(current.prefix(previous.count)) == previous
    }
}
