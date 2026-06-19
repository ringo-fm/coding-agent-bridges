import AgentBridgeCore
import Foundation

struct PreparedCodexContext: Sendable {
    let conversation: ConversationRecord
    let plan: ContextPlan
    let instructions: String
    let prompt: String
    let sessionKey: String
    let sessionFingerprint: String
    let resultingSessionFingerprint: String
    let incrementalPrompt: String
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
        var previousRecord: ConversationRecord?
        var chain: [ConversationRecord] = []
        if let previousID = request.previous_response_id,
           let previous = try await ledger.conversation(id: previousID) {
            previousRecord = previous
            previousHashes = previous.turnHashes
            chain = try await ancestry(endingAt: previous, ledger: ledger)
            for record in chain {
                let prior = try await ledger.segments(for: record.id, limit: 64)
                candidates.append(contentsOf: prior.map {
                    ContextSegment(
                        id: "prior-\(record.id)-\($0.id)",
                        kind: $0.kind == .unresolvedToolResult ? .unresolvedToolResult : .olderConversation,
                        text: $0.text,
                        sourceTurnID: $0.sourceTurnID,
                        metadata: $0.metadata
                    )
                })
            }
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
        let baseFingerprint = ConversationFingerprint.conversationKey(
            protocolName: "codex",
            instructions: normalized.instructions ?? "",
            toolCatalog: toolCatalog,
            turnHashes: []
        )
        let sessionKey = chain.first?.id ?? responseID
        let sessionFingerprint = baseFingerprint + "|head:" + (request.previous_response_id ?? "root")
        let resultingSessionFingerprint = baseFingerprint + "|head:" + responseID
        let conversation = ConversationRecord(
            id: responseID,
            protocolName: "codex",
            fingerprint: baseFingerprint,
            turnHashes: previousHashes + currentHashes,
            parentConversationID: previousRecord?.id
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
        // AFM counts the selected native tool schema and structured-output
        // routing guide inside the same context window. Keep a dedicated
        // quarter-window reserve when tools are advertised; only one selected
        // schema is supplied during generation.
        let toolReserve = (request.tools?.isEmpty == false) ? min(1_024, contextSize / 4) : 0
        let estimatorSafetyReserve = min(512, contextSize / 8)
        let budget = max(256, contextSize - reserve - toolReserve - estimatorSafetyReserve)
        let initialPlan = ContextPlanner.plan(segments: candidates, budget: budget)
        candidates = try await ContextCompaction.addCapsuleIfNeeded(
            to: candidates,
            initialPlan: initialPlan,
            conversationID: conversation.id,
            ledger: ledger
        )
        let plan = ContextPlanner.plan(segments: candidates, budget: budget)
        let instructionKinds: Set<ContextSegmentKind> = [.instruction, .requiredTool, .summary]
        let instructions = plan.segments
            .filter { instructionKinds.contains($0.kind) }
            .map(\.text)
            .joined(separator: "\n\n")
        let prompt = plan.segments
            .filter { !instructionKinds.contains($0.kind) }
            .map(\.text)
            .joined(separator: "\n\n")
        return PreparedCodexContext(
            conversation: conversation,
            plan: plan,
            instructions: instructions,
            prompt: prompt.isEmpty ? "[user] Continue." : prompt,
            sessionKey: sessionKey,
            sessionFingerprint: sessionFingerprint,
            resultingSessionFingerprint: resultingSessionFingerprint,
            incrementalPrompt: current
                .filter { $0.kind != .instruction && $0.kind != .requiredTool }
                .map(\.text).joined(separator: "\n\n")
        )
    }

    private static func ancestry(
        endingAt record: ConversationRecord,
        ledger: any ContextLedger,
        limit: Int = 64
    ) async throws -> [ConversationRecord] {
        var reversed: [ConversationRecord] = []
        var current: ConversationRecord? = record
        var visited: Set<String> = []
        while let node = current, reversed.count < limit, visited.insert(node.id).inserted {
            reversed.append(node)
            guard let parentID = node.parentConversationID else { break }
            current = try await ledger.conversation(id: parentID)
        }
        return reversed.reversed()
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
