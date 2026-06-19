import AgentBridgeCore
import Foundation

struct PreparedCodexContext: Sendable {
    let conversation: ConversationRecord
    let plan: ContextPlan
}

enum CodexContextPlanner {
    static func prepare(
        request: ResponsesCreateRequest,
        normalized: NormalizedInput,
        responseID: String,
        contextSize: Int,
        ledger: any ContextLedger
    ) async throws -> PreparedCodexContext {
        let current = makeSegments(request: request, normalized: normalized)
        var candidates: [ContextSegment] = []
        var previousHashes: [String] = []
        if let previousID = request.previous_response_id,
           let previous = try await ledger.conversation(id: previousID) {
            previousHashes = previous.turnHashes
            let prior = try await ledger.segments(for: previous.id, limit: 64)
            candidates.append(contentsOf: prior.map {
                ContextSegment(
                    id: "prior-\($0.id)",
                    kind: $0.kind == .unresolvedToolResult ? .unresolvedToolResult : .olderConversation,
                    text: $0.text,
                    sourceTurnID: $0.sourceTurnID,
                    metadata: $0.metadata
                )
            })
        }
        candidates.append(contentsOf: current)

        let query = current.last(where: { $0.kind == .currentRequest })?.text ?? ""
        if !query.isEmpty {
            let retrieved = try await ledger.searchArtifacts(query: query, limit: 4)
            candidates.append(contentsOf: retrieved.map {
                ContextSegment(
                    id: "retrieved-\($0.hash)",
                    kind: .retrievedSource,
                    text: "[retrieved source]\n\($0.text)",
                    metadata: $0.metadata
                )
            })
        }

        let currentHashes = current.filter { $0.sourceTurnID != nil }.map { ConversationFingerprint.digest($0.text) }
        let toolCatalog = request.tools?.map { ($0.name ?? $0.type) + ":" + ($0.description ?? "") }.joined(separator: "\n") ?? ""
        let fingerprint = ConversationFingerprint.conversationKey(
            protocolName: "codex",
            instructions: normalized.instructions ?? "",
            toolCatalog: toolCatalog,
            turnHashes: previousHashes + currentHashes
        )
        let conversation = ConversationRecord(
            id: responseID,
            protocolName: "codex",
            fingerprint: fingerprint,
            turnHashes: previousHashes + currentHashes
        )
        try await ledger.saveConversation(conversation)
        for segment in current {
            try await ledger.append(segment, to: responseID)
            if segment.text.utf8.count >= 256 {
                let hash = ConversationFingerprint.digest(segment.text)
                try await ledger.cacheArtifact(
                    hash: hash,
                    text: segment.text,
                    metadata: segment.metadata.merging(["kind": segment.kind.rawValue]) { current, _ in current }
                )
            }
        }

        let reserve = min(max(request.max_output_tokens ?? PromptBuilder.defaultOutputReserve, 128), max(128, contextSize / 2))
        let plan = ContextPlanner.plan(segments: candidates, budget: max(256, contextSize - reserve))
        return PreparedCodexContext(conversation: conversation, plan: plan)
    }

    private static func makeSegments(
        request: ResponsesCreateRequest,
        normalized: NormalizedInput
    ) -> [ContextSegment] {
        var segments = [ContextSegment(id: "codex-preamble", kind: .instruction, text: PromptBuilder.preamble)]
        if let instructions = normalized.instructions, !instructions.isEmpty {
            segments.append(ContextSegment(
                id: "instructions-" + ConversationFingerprint.digest(instructions),
                kind: .instruction,
                text: "System instructions:\n\(instructions)"
            ))
        }
        if let tools = request.tools, !tools.isEmpty {
            let catalog = tools.map { tool in
                "Tool \(tool.name ?? tool.type): \(tool.description ?? "")"
            }.joined(separator: "\n")
            segments.append(ContextSegment(
                id: "tools-" + ConversationFingerprint.digest(catalog),
                kind: .requiredTool,
                text: catalog,
                metadata: ["relation": "tool_catalog"]
            ))
        }

        let recentStart = max(0, normalized.messages.count - 4)
        let lastUser = normalized.messages.lastIndex { $0.role == .user }
        for (index, message) in normalized.messages.enumerated() {
            let rendered = "[\(message.role.rawValue)] \(message.text)"
            let kind: ContextSegmentKind
            switch message.role {
            case .system, .developer:
                kind = .instruction
            case .user where index == lastUser:
                kind = .currentRequest
            default:
                kind = index >= recentStart ? .recentConversation : .olderConversation
            }
            segments.append(ContextSegment(
                id: "message-" + ConversationFingerprint.digest("\(index):\(rendered)"),
                kind: kind,
                text: rendered,
                sourceTurnID: String(index),
                metadata: ["role": message.role.rawValue]
            ))
        }
        for output in normalized.toolOutputs {
            let rendered = "[tool_output \(output.callID)] \(output.output)"
            segments.append(ContextSegment(
                id: "tool-output-" + ConversationFingerprint.digest(rendered),
                kind: .unresolvedToolResult,
                text: rendered,
                sourceTurnID: output.callID,
                metadata: ["relation": "tool_result"]
            ))
        }
        for call in normalized.toolCalls {
            let rendered = "[assistant tool_call] \(call.name)(\(call.arguments))"
            segments.append(ContextSegment(
                id: "tool-call-" + ConversationFingerprint.digest(rendered),
                kind: .recentConversation,
                text: rendered,
                sourceTurnID: call.callID,
                metadata: ["relation": "tool_call", "tool": call.name]
            ))
        }
        return segments
    }
}
