import AgentBridgeCore
import Testing
@testable import ClaudeAdapter

@Suite("Claude context continuity")
struct ClaudeContextContinuityTests {
    @Test func appendOnlyHistoryReusesSessionAndBranchCreatesAnother() async throws {
        let ledger = InMemoryContextLedger()
        let first = request([turn("first")])
        let preparedFirst = try await ClaudeContextPlanner.prepare(first, contextSize: 4096, ledger: ledger)

        let continued = request([turn("first"), turn("second")])
        let preparedContinued = try await ClaudeContextPlanner.prepare(continued, contextSize: 4096, ledger: ledger)

        let branch = request([turn("different"), turn("second")])
        let preparedBranch = try await ClaudeContextPlanner.prepare(branch, contextSize: 4096, ledger: ledger)

        #expect(preparedFirst.sessionKey == preparedContinued.sessionKey)
        #expect(preparedContinued.incrementalPrompt.contains("second"))
        #expect(preparedBranch.sessionKey != preparedContinued.sessionKey)
    }

    private func request(_ turns: [NormalizedTurn]) -> NormalizedRequest {
        NormalizedRequest(
            model: "claude-afm-local",
            systemText: "system",
            turns: turns,
            stream: false,
            temperature: nil,
            maxTokens: 128,
            tools: nil,
            toolChoicePresent: false,
            thinkingPresent: false
        )
    }

    private func turn(_ text: String) -> NormalizedTurn {
        NormalizedTurn(role: "user", blocks: [NormalizedBlock(kind: .text(text))])
    }
}
