import AgentBridgeCore
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
}
