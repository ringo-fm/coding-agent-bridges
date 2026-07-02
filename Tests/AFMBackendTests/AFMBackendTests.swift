import AgentBridgeCore
import Foundation
import XCTest
@testable import AFMBackend

final class AFMSessionPoolTests: XCTestCase {
    func testConfigurationClampsInvalidBounds() {
        let configuration = AFMSessionPoolConfiguration(maximumSessions: 0, ttl: 0)
        XCTAssertEqual(configuration.maximumSessions, 1)
        XCTAssertEqual(configuration.ttl, 1)
    }

    func testPoolStartsEmpty() async {
        let pool = AFMSessionPool()
        let stats = await pool.stats()
        XCTAssertEqual(stats, AFMSessionPoolStats(activeSessions: 0, hits: 0, misses: 0, evictions: 0))
    }

    func testLiveGenerationSessionReuseAndStreaming() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_FM_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_FM_TESTS=1 to run Apple Foundation Models integration tests")
        }

        let backend = FoundationModelsBackend()
        guard case .available = backend.status() else {
            throw XCTSkip("Apple Foundation Models unavailable")
        }

        let first = try await backend.generate(AgentGenerationRequest(
            model: "apple-foundation-local",
            messages: [AgentMessage(role: .user, text: "Reply with exactly: one")],
            maximumOutputTokens: 16,
            conversationKey: "live-session",
            contextFingerprint: "stable",
            incrementalMessages: [AgentMessage(role: .user, text: "Reply with exactly: one")]
        ))
        XCTAssertFalse(first.text.isEmpty)

        let second = try await backend.generate(AgentGenerationRequest(
            model: "apple-foundation-local",
            messages: [AgentMessage(role: .user, text: "Now reply with exactly: two")],
            maximumOutputTokens: 16,
            conversationKey: "live-session",
            contextFingerprint: "stable",
            incrementalMessages: [AgentMessage(role: .user, text: "Now reply with exactly: two")]
        ))
        XCTAssertFalse(second.text.isEmpty)

        let stream = try await backend.stream(AgentGenerationRequest(
            model: "apple-foundation-local",
            messages: [AgentMessage(role: .user, text: "Reply with exactly: stream")],
            stream: true,
            maximumOutputTokens: 16
        ))
        var completed = false
        for try await event in stream {
            if case .completed(let result) = event {
                completed = !result.text.isEmpty
            }
        }
        XCTAssertTrue(completed)
    }

    func testLiveAdaptiveExternalToolSelection() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_FM_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_FM_TESTS=1 to run Apple Foundation Models integration tests")
        }
        let backend = FoundationModelsBackend()
        guard case .available = backend.status() else {
            throw XCTSkip("Apple Foundation Models unavailable")
        }
        let result = try await backend.generate(AgentGenerationRequest(
            model: "apple-foundation-local",
            messages: [AgentMessage(role: .user, text: "Inspect TASK.md and complete its requested file change.")],
            tools: [AgentToolDefinition(
                name: "exec_command",
                description: "Run a shell command in the repository to inspect files or perform requested actions.",
                inputSchemaJSON: #"{"type":"object","properties":{"cmd":{"type":"string","description":"Complete shell command"}},"required":["cmd"]}"#
            )],
            maximumOutputTokens: 64,
            decisionContext: "[user] Inspect TASK.md and complete its requested file change."
        ))
        XCTAssertEqual(result.toolCalls.first?.name, "exec_command")
        XCTAssertFalse(result.toolCalls.first?.argumentsJSON.isEmpty ?? true)
    }
}
