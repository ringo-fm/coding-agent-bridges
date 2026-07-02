import AgentBridgeCore
import Foundation

struct PreparedClaudeContext: Sendable {
    let conversation: ConversationRecord
    let plan: ContextPlan
    let instructions: String
    let prompt: String
    let sessionKey: String
    let sessionFingerprint: String
    let resultingSessionFingerprint: String
    let incrementalPrompt: String
}

enum ClaudeContextPlanner {
    static func prepare(
        _ request: NormalizedRequest,
        contextSize: Int,
        ledger: any ContextLedger
    ) async throws -> PreparedClaudeContext {
        var segments = makeSegments(request)
        let turnHashes = request.turns.map { ConversationFingerprint.digest(render($0)) }
        let toolCatalog = request.tools?.map(\.summary).joined(separator: "\n") ?? ""
        let baseFingerprint = ConversationFingerprint.conversationKey(
            protocolName: "claude",
            instructions: request.systemText ?? "",
            toolCatalog: toolCatalog,
            turnHashes: []
        )
        let previous = try await ledger.conversation(fingerprint: baseFingerprint)
        let continuation = previous.map {
            ConversationFingerprint.isAppendOnly(previous: $0.turnHashes, current: turnHashes)
        } ?? false
        let query = segments.last(where: { $0.kind == .currentRequest })?.text ?? ""
        if continuation, !query.isEmpty {
            let retrieved = try await ledger.searchArtifacts(query: query, limit: 4)
            segments.append(contentsOf: retrieved.map {
                ContextSegment(
                    id: "retrieved-\($0.hash)",
                    kind: .retrievedSource,
                    text: "[retrieved source]\n\($0.text)",
                    metadata: $0.metadata
                )
            })
        }
        let conversation = ConversationRecord(
            id: continuation ? previous!.id : UUID().uuidString,
            protocolName: "claude",
            fingerprint: baseFingerprint,
            turnHashes: turnHashes
        )

        try await ledger.saveConversation(conversation)
        for segment in segments where segment.kind != .retrievedSource {
            try await ledger.append(segment, to: conversation.id)
            if segment.text.utf8.count >= 256 {
                let hash = ConversationFingerprint.digest(segment.text)
                try await ledger.cacheArtifact(
                    hash: hash,
                    text: segment.text,
                    metadata: segment.metadata.merging(["kind": segment.kind.rawValue]) { current, _ in current }
                )
            }
        }

        let reserve = min(max(request.maxTokens ?? 512, 128), max(128, contextSize / 2))
        let budget = max(256, contextSize - reserve)
        let initialPlan = ContextPlanner.plan(segments: segments, budget: budget)
        segments = try await ContextCompaction.addCapsuleIfNeeded(
            to: segments,
            initialPlan: initialPlan,
            conversationID: conversation.id,
            ledger: ledger
        )
        let plan = ContextPlanner.plan(segments: segments, budget: budget)
        let instructionKinds: Set<ContextSegmentKind> = [.instruction, .requiredTool, .summary]
        let instructions = plan.segments.filter { instructionKinds.contains($0.kind) }.map(\.text).joined(separator: "\n\n")
        let prompt = plan.segments.filter { !instructionKinds.contains($0.kind) }.map(\.text).joined(separator: "\n")
        return PreparedClaudeContext(
            conversation: conversation,
            plan: plan,
            instructions: instructions.isEmpty ? TranscriptBuilder.header : instructions,
            prompt: prompt.isEmpty ? "[user] Continue." : prompt,
            sessionKey: conversation.id,
            sessionFingerprint: baseFingerprint + "|head:" + ConversationFingerprint.digest(turnHashes.dropLast().joined(separator: "|")),
            resultingSessionFingerprint: baseFingerprint + "|head:" + ConversationFingerprint.digest(turnHashes.joined(separator: "|")),
            incrementalPrompt: segments.last(where: { $0.kind == .currentRequest })?.text ?? prompt
        )
    }

    private static func makeSegments(_ request: NormalizedRequest) -> [ContextSegment] {
        var segments = [ContextSegment(
            id: "claude-header",
            kind: .instruction,
            text: TranscriptBuilder.header
        )]
        if let system = request.systemText, !system.isEmpty {
            segments.append(ContextSegment(
                id: "system-" + ConversationFingerprint.digest(system),
                kind: .instruction,
                text: "System instructions:\n\(system)"
            ))
        }
        if let tools = request.tools, !tools.isEmpty {
            let catalog = ToolMapper.buildCompactToolCatalog(tools: tools)
            segments.append(ContextSegment(
                id: "tools-" + ConversationFingerprint.digest(catalog),
                kind: .requiredTool,
                text: catalog,
                metadata: ["relation": "tool_catalog"]
            ))
        }

        let recentStart = max(0, request.turns.count - 4)
        for (index, turn) in request.turns.enumerated() {
            let rendered = render(turn)
            let hasToolResult = turn.blocks.contains { block in
                if case .toolResult = block.kind { return true }
                return false
            }
            let isCurrent = index == request.turns.count - 1 && turn.role == "user"
            let kind: ContextSegmentKind = isCurrent
                ? .currentRequest
                : (hasToolResult ? .unresolvedToolResult : (index >= recentStart ? .recentConversation : .olderConversation))
            segments.append(ContextSegment(
                id: "turn-" + ConversationFingerprint.digest("\(index):\(rendered)"),
                kind: kind,
                text: rendered,
                sourceTurnID: String(index),
                metadata: ["role": turn.role]
            ))
        }
        return segments
    }

    private static func render(_ turn: NormalizedTurn) -> String {
        turn.blocks.map { block in
            switch block.kind {
            case .text(let text):
                return "[\(turn.role)] \(text)"
            case .toolResult(let result):
                return "[tool_result id=\(result.toolUseId) is_error=\(result.isError)]\n\(result.content)\n[/tool_result]"
            case .toolUse(let name, let id, let input):
                return "[\(turn.role) tool_use name=\(name ?? "unknown") id=\(id ?? "unknown")] input=\(input ?? "{}")"
            case .thinking:
                return ""
            case .unsupported(let type):
                return "[\(turn.role) unsupported_block type=\(type)]"
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
