import Foundation
import SQLite3
import XCTest
@testable import AgentBridgeCore

final class ContextPlannerTests: XCTestCase {
    func testPriorityKeepsCurrentRequestAndToolResult() {
        let segments = [
            ContextSegment(id: "old", kind: .olderConversation, text: String(repeating: "old ", count: 100)),
            ContextSegment(id: "tool", kind: .unresolvedToolResult, text: "compiler failed"),
            ContextSegment(id: "current", kind: .currentRequest, text: "fix the build"),
        ]

        let plan = ContextPlanner.plan(segments: segments, budget: 20)

        XCTAssertEqual(plan.segments.map(\.id), ["tool", "current"])
        XCTAssertEqual(plan.omittedSegmentIDs, ["old"])
        XCTAssertTrue(plan.truncated)
    }

    func testCurrentRequestIsBoundedButNeverDropped() {
        let plan = ContextPlanner.plan(
            segments: [ContextSegment(id: "current", kind: .currentRequest, text: String(repeating: "x", count: 1_000))],
            budget: 20
        )

        XCTAssertEqual(plan.segments.map(\.id), ["current"])
        XCTAssertLessThanOrEqual(plan.estimatedTokens, 30)
        XCTAssertTrue(plan.truncated)
    }

    func testInstructionsAndCurrentRequestAreProtectedUnderPressure() {
        let plan = ContextPlanner.plan(segments: [
            ContextSegment(id: "instruction", kind: .instruction, text: String(repeating: "system ", count: 100)),
            ContextSegment(id: "retrieved", kind: .retrievedSource, text: String(repeating: "source ", count: 100)),
            ContextSegment(id: "recent", kind: .recentConversation, text: String(repeating: "recent ", count: 100)),
            ContextSegment(id: "current", kind: .currentRequest, text: "do the requested work"),
        ], budget: 20)

        XCTAssertTrue(plan.segments.contains { $0.id == "instruction" })
        XCTAssertTrue(plan.segments.contains { $0.id == "current" })
        XCTAssertFalse(plan.segments.contains { $0.id == "retrieved" })
        XCTAssertFalse(plan.segments.contains { $0.id == "recent" })
    }

    func testFingerprintDetectsAppendOnlyTurns() {
        let first = ["a", "b"]
        XCTAssertTrue(ConversationFingerprint.isAppendOnly(previous: first, current: first + ["c"]))
        XCTAssertFalse(ConversationFingerprint.isAppendOnly(previous: first, current: ["a", "x"]))
        XCTAssertEqual(ConversationFingerprint.digest("stable"), ConversationFingerprint.digest("stable"))
    }
}

final class ContextLedgerTests: XCTestCase {
    func testMemoryLedgerStoresConversationSegmentsAndArtifacts() async throws {
        let ledger = InMemoryContextLedger()
        let conversation = ConversationRecord(
            id: "conversation",
            protocolName: "codex",
            fingerprint: "fingerprint",
            turnHashes: ["one"]
        )
        await ledger.saveConversation(conversation)
        await ledger.append(ContextSegment(id: "turn", kind: .currentRequest, text: "Fix Widget.swift"), to: conversation.id)
        await ledger.cacheArtifact(hash: "artifact", text: "Widget.swift compiler failure", metadata: ["path": "Widget.swift"])

        let restored = await ledger.conversation(fingerprint: "fingerprint")
        let segments = await ledger.segments(for: conversation.id, limit: 10)
        let artifacts = await ledger.searchArtifacts(query: "Widget compiler", limit: 5)
        XCTAssertEqual(restored?.id, conversation.id)
        XCTAssertEqual(segments.map(\.id), ["turn"])
        XCTAssertEqual(artifacts.first?.hash, "artifact")
    }

    func testSQLiteLedgerSurvivesRestartAndSearchesFTS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("context.sqlite3").path
        let capsule = ContextCapsule(objective: "Ship bridge", filesAndSymbols: ["Sources/App.swift"])

        do {
            let ledger = try SQLiteContextLedger(path: path)
            try await ledger.saveConversation(ConversationRecord(
                id: "conversation",
                protocolName: "claude",
                fingerprint: "fingerprint",
                turnHashes: ["one", "two"]
            ))
            try await ledger.append(ContextSegment(id: "turn", kind: .recentConversation, text: "Inspect Sources/App.swift"), to: "conversation")
            try await ledger.saveCapsule(capsule, for: "conversation")
            try await ledger.cacheArtifact(
                hash: "artifact",
                text: "fatal compiler error in Sources/App.swift",
                metadata: ["path": "Sources/App.swift", "symbol": "App"]
            )
        }

        do {
            let reopened = try SQLiteContextLedger(path: path)
            let restored = try await reopened.conversation(id: "conversation")
            let segments = try await reopened.segments(for: "conversation", limit: 10)
            let restoredCapsule = try await reopened.capsule(for: "conversation")
            let artifacts = try await reopened.searchArtifacts(query: "compiler App.swift", limit: 5)
            XCTAssertEqual(restored?.turnHashes, ["one", "two"])
            XCTAssertEqual(segments.map(\.id), ["turn"])
            XCTAssertEqual(restoredCapsule, capsule)
            XCTAssertEqual(artifacts.first?.hash, "artifact")
        }

        try? FileManager.default.removeItem(at: directory)
    }

    func testSQLiteScopesDuplicateSegmentIDsByConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = try SQLiteContextLedger(path: directory.appendingPathComponent("context.sqlite3").path)
        for id in ["one", "two"] {
            try await ledger.saveConversation(ConversationRecord(id: id, protocolName: "test", fingerprint: id, turnHashes: []))
            try await ledger.append(ContextSegment(id: "shared", kind: .instruction, text: "segment for \(id)"), to: id)
        }
        let one = try await ledger.segments(for: "one", limit: 10)
        let two = try await ledger.segments(for: "two", limit: 10)
        XCTAssertEqual(one.map(\.text), ["segment for one"])
        XCTAssertEqual(two.map(\.text), ["segment for two"])
    }

    func testSQLiteMigratesV1WithoutLosingTurnsOrCapsule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("context.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        let capsule = #"{"objective":"keep me","constraints":[],"decisions":[],"filesAndSymbols":[],"completedActions":[],"failedAttempts":[],"pendingTasks":[],"sourceTurnIDs":[]}"#
        let sql = """
        CREATE TABLE conversations(id TEXT PRIMARY KEY, protocol_name TEXT NOT NULL, fingerprint TEXT NOT NULL, turn_hashes_json TEXT NOT NULL, capsule_json TEXT, updated_at REAL NOT NULL);
        CREATE INDEX conversations_fingerprint ON conversations(fingerprint, updated_at DESC);
        CREATE TABLE turns(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, source_turn_id TEXT, metadata_json TEXT NOT NULL, created_at REAL NOT NULL, UNIQUE(conversation_id, ordinal));
        CREATE TABLE artifacts(hash TEXT PRIMARY KEY, text TEXT NOT NULL, metadata_json TEXT NOT NULL, created_at REAL NOT NULL, last_accessed_at REAL NOT NULL);
        CREATE VIRTUAL TABLE artifact_fts USING fts5(hash UNINDEXED, text, metadata);
        INSERT INTO conversations VALUES('legacy','codex','fingerprint','[\"one\"]','\(capsule)',0);
        INSERT INTO turns VALUES('turn','legacy',0,'recentConversation','legacy text',NULL,'{}',0);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let migrated = try SQLiteContextLedger(path: path)
        let segments = try await migrated.segments(for: "legacy", limit: 10)
        let restoredCapsule = try await migrated.capsule(for: "legacy")
        let conversation = try await migrated.conversation(id: "legacy")
        XCTAssertEqual(segments.map(\.text), ["legacy text"])
        XCTAssertEqual(restoredCapsule?.objective, "keep me")
        XCTAssertNil(conversation?.parentConversationID)
    }
}

final class ContextCompactionTests: XCTestCase {
    func testDeterministicCapsulePreservesStructuredFacts() async throws {
        let segments = [
            ContextSegment(
                kind: .olderConversation,
                text: "Decision: use SQLite. The build failed in Sources/App.swift. TODO: rerun tests.",
                sourceTurnID: "turn-1"
            )
        ]
        let capsule = try await DeterministicContextSummarizer().summarize(segments)

        XCTAssertTrue(capsule.decisions.contains { $0.contains("SQLite") })
        XCTAssertTrue(capsule.failedAttempts.contains { $0.contains("failed") })
        XCTAssertTrue(capsule.filesAndSymbols.contains { $0.contains("Sources/App.swift") })
        XCTAssertEqual(capsule.sourceTurnIDs, ["turn-1"])
    }

    func testCompactionPersistsCapsuleAndAddsSummary() async throws {
        let ledger = InMemoryContextLedger()
        let record = ConversationRecord(id: "conversation", protocolName: "test", fingerprint: "f", turnHashes: [])
        await ledger.saveConversation(record)
        let old = ContextSegment(id: "old", kind: .olderConversation, text: String(repeating: "old error Sources/A.swift ", count: 100))
        let current = ContextSegment(id: "current", kind: .currentRequest, text: "continue")
        let plan = ContextPlanner.plan(segments: [old, current], budget: 10)

        let compacted = try await ContextCompaction.addCapsuleIfNeeded(
            to: [old, current],
            initialPlan: plan,
            conversationID: record.id,
            ledger: ledger
        )

        XCTAssertTrue(compacted.contains { $0.kind == .summary })
        let restored = await ledger.capsule(for: record.id)
        XCTAssertNotNil(restored)
    }
}
