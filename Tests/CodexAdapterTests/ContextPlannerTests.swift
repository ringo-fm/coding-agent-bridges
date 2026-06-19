import AgentBridgeCore
import Foundation
import Testing
@testable import CodexAdapter

@Suite("Codex context continuity")
struct CodexContextContinuityTests {
    @Test func previousResponseKeepsSessionKeyAndUsesIncrementalPrompt() async throws {
        let ledger = InMemoryContextLedger()
        let firstRequest = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .text("first request")
        )
        let firstNormalized = InputNormalizer.normalize(firstRequest, flags: .codexMinimal)
        let first = try await CodexContextPlanner.prepare(
            request: firstRequest,
            normalized: firstNormalized,
            responseID: "resp_1",
            contextSize: 4096,
            ledger: ledger
        )

        let secondRequest = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .text("second request"),
            previous_response_id: "resp_1"
        )
        let secondNormalized = InputNormalizer.normalize(secondRequest, flags: .codexMinimal)
        let second = try await CodexContextPlanner.prepare(
            request: secondRequest,
            normalized: secondNormalized,
            responseID: "resp_2",
            contextSize: 4096,
            ledger: ledger
        )

        #expect(first.sessionKey == second.sessionKey)
        #expect(second.incrementalPrompt.contains("second request"))
        #expect(!second.incrementalPrompt.contains(PromptBuilder.preamble))
        #expect(second.plan.prompt.contains("first request"))
    }

    @Test func restartRestoresThreeTurnChain() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("context.sqlite3").path
        do {
            let ledger = try SQLiteContextLedger(path: path)
            _ = try await prepare("A", id: "resp_a", previous: nil, ledger: ledger)
            _ = try await prepare("B", id: "resp_b", previous: "resp_a", ledger: ledger)
        }
        let reopened = try SQLiteContextLedger(path: path)
        let third = try await prepare("C", id: "resp_c", previous: "resp_b", ledger: reopened)
        #expect(third.plan.prompt.contains("A"))
        #expect(third.plan.prompt.contains("B"))
        #expect(third.plan.prompt.contains("C"))
        #expect(third.conversation.parentConversationID == "resp_b")
    }

    @Test func branchUsesParentHeadFingerprintAndExcludesSibling() async throws {
        let ledger = InMemoryContextLedger()
        _ = try await prepare("A", id: "resp_a", previous: nil, ledger: ledger)
        let b = try await prepare("B sibling", id: "resp_b", previous: "resp_a", ledger: ledger)
        let c = try await prepare("C branch", id: "resp_c", previous: "resp_a", ledger: ledger)

        #expect(b.sessionFingerprint == c.sessionFingerprint)
        #expect(b.resultingSessionFingerprint != c.resultingSessionFingerprint)
        #expect(c.plan.prompt.contains("A"))
        #expect(c.plan.prompt.contains("C branch"))
        #expect(!c.plan.prompt.contains("B sibling"))
    }

    private func prepare(
        _ text: String,
        id: String,
        previous: String?,
        ledger: any ContextLedger
    ) async throws -> PreparedCodexContext {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .text(text),
            previous_response_id: previous
        )
        return try await CodexContextPlanner.prepare(
            request: request,
            normalized: InputNormalizer.normalize(request, flags: .codexMinimal),
            responseID: id,
            contextSize: 4096,
            ledger: ledger
        )
    }
}
