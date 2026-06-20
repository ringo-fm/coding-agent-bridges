import Foundation
import SQLite3

public enum ContextLedgerError: Error, Sendable, CustomStringConvertible {
    case open(path: String, message: String)
    case sqlite(operation: String, message: String)
    case encoding(String)

    public var description: String {
        switch self {
        case .open(let path, let message): "Could not open context database at \(path): \(message)"
        case .sqlite(let operation, let message): "SQLite \(operation) failed: \(message)"
        case .encoding(let message): "Context encoding failed: \(message)"
        }
    }
}

public enum ContextLedgerFactory {
    public static func make(
        mode: ContextStorageMode,
        path: String? = nil,
        retentionDays: Int = 30
    ) throws -> any ContextLedger {
        switch mode {
        case .off:
            return DisabledContextLedger()
        case .memory:
            return InMemoryContextLedger(retentionDays: retentionDays)
        case .persistent:
            return try SQLiteContextLedger(
                path: path ?? defaultPersistentPath(),
                retentionDays: retentionDays
            )
        }
    }

    public static func defaultPersistentPath() -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("coding-agent-bridges", isDirectory: true)
            .appendingPathComponent("context.sqlite3")
            .path
    }
}

public actor SQLiteContextLedger: ContextLedger {
    private let handle: SQLiteDatabaseHandle
    private var db: OpaquePointer { handle.pointer }
    private let retentionInterval: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let path: String

    public init(path: String, retentionDays: Int = 30) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let opened { sqlite3_close(opened) }
            throw ContextLedgerError.open(path: path, message: message)
        }

        do {
            try Self.migrate(db: opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        handle = SQLiteDatabaseHandle(opened)
        retentionInterval = TimeInterval(max(1, retentionDays) * 86_400)
    }

    public func storageStatus() -> ContextStorageStatus { .init(mode: .persistent, path: path) }

    public func listConversations(limit: Int) throws -> [SessionSummary] {
        let statement = try prepare(
            """
            SELECT c.id, c.protocol_name, c.updated_at, c.parent_conversation_id,
                   json_array_length(c.turn_hashes_json), COUNT(t.id), c.capsule_json IS NOT NULL
            FROM conversations c LEFT JOIN turns t ON t.conversation_id = c.id
            GROUP BY c.id ORDER BY c.updated_at DESC LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(max(0, limit)))], to: statement)
        var result: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(SessionSummary(
                id: text(statement, 0),
                protocolName: text(statement, 1),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                parentConversationID: optionalText(statement, 3),
                turnCount: Int(sqlite3_column_int(statement, 4)),
                segmentCount: Int(sqlite3_column_int(statement, 5)),
                hasCapsule: sqlite3_column_int(statement, 6) != 0
            ))
        }
        try checkRead(statement, operation: "list conversations")
        return result
    }

    public func saveConversation(_ conversation: ConversationRecord) throws {
        let hashes = try json(conversation.turnHashes)
        try execute(
            """
            INSERT INTO conversations(id, protocol_name, fingerprint, turn_hashes_json, parent_conversation_id, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              protocol_name=excluded.protocol_name,
              fingerprint=excluded.fingerprint,
              turn_hashes_json=excluded.turn_hashes_json,
              parent_conversation_id=excluded.parent_conversation_id,
              updated_at=excluded.updated_at
            """,
            bindings: [
                .text(conversation.id), .text(conversation.protocolName),
                .text(conversation.fingerprint), .text(hashes),
                conversation.parentConversationID.map(Binding.text) ?? .null,
                .double(conversation.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    public func conversation(id: String) throws -> ConversationRecord? {
        try readConversation(where: "id = ?", value: id)
    }

    public func conversation(fingerprint: String) throws -> ConversationRecord? {
        try readConversation(where: "fingerprint = ?", value: fingerprint)
    }

    public func append(_ segment: ContextSegment, to conversationID: String) throws {
        try execute(
            """
            INSERT INTO turns(id, conversation_id, ordinal, kind, text, source_turn_id, metadata_json, created_at)
            VALUES(
              ?, ?,
              COALESCE((SELECT MAX(ordinal) + 1 FROM turns WHERE conversation_id = ?), 0),
              ?, ?, ?, ?, ?
            )
            ON CONFLICT(conversation_id, id) DO NOTHING
            """,
            bindings: [
                .text(segment.id), .text(conversationID), .text(conversationID),
                .text(segment.kind.rawValue), .text(segment.text),
                segment.sourceTurnID.map(Binding.text) ?? .null,
                .text(try json(segment.metadata)), .double(Date().timeIntervalSince1970),
            ]
        )
    }

    public func segments(for conversationID: String, limit: Int) throws -> [ContextSegment] {
        let statement = try prepare(
            """
            SELECT id, kind, text, source_turn_id, metadata_json
            FROM turns WHERE conversation_id = ?
            ORDER BY ordinal DESC LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(conversationID), .integer(Int64(max(0, limit)))], to: statement)

        var result: [ContextSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = ContextSegmentKind(rawValue: text(statement, 1)) else { continue }
            let metadata: [String: String] = try decodeJSON(text(statement, 4))
            result.append(ContextSegment(
                id: text(statement, 0),
                kind: kind,
                text: text(statement, 2),
                sourceTurnID: optionalText(statement, 3),
                metadata: metadata
            ))
        }
        try checkRead(statement, operation: "read segments")
        return result.reversed()
    }

    public func saveCapsule(_ capsule: ContextCapsule, for conversationID: String) throws {
        try execute(
            "UPDATE conversations SET capsule_json = ?, updated_at = ? WHERE id = ?",
            bindings: [
                .text(try json(capsule)),
                .double(Date().timeIntervalSince1970),
                .text(conversationID),
            ]
        )
    }

    public func capsule(for conversationID: String) throws -> ContextCapsule? {
        let statement = try prepare("SELECT capsule_json FROM conversations WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(conversationID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = optionalText(statement, 0) else {
            try checkRead(statement, operation: "read capsule", allowDone: true)
            return nil
        }
        return try decodeJSON(value)
    }

    public func cacheArtifact(hash: String, text: String, metadata: [String: String]) throws {
        let now = Date().timeIntervalSince1970
        let metadataJSON = try json(metadata)
        try transaction {
            try execute(
                """
                INSERT INTO artifacts(hash, text, metadata_json, created_at, last_accessed_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(hash) DO UPDATE SET
                  text=excluded.text,
                  metadata_json=excluded.metadata_json,
                  last_accessed_at=excluded.last_accessed_at
                """,
                bindings: [.text(hash), .text(text), .text(metadataJSON), .double(now), .double(now)]
            )
            try execute("DELETE FROM artifact_fts WHERE hash = ?", bindings: [.text(hash)])
            try execute(
                "INSERT INTO artifact_fts(hash, text, metadata) VALUES(?, ?, ?)",
                bindings: [.text(hash), .text(text), .text(metadata.values.joined(separator: " "))]
            )
        }
    }

    public func artifact(hash: String) throws -> RetrievedArtifact? {
        let statement = try prepare("SELECT text, metadata_json FROM artifacts WHERE hash = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(hash)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkRead(statement, operation: "read artifact", allowDone: true)
            return nil
        }
        try execute(
            "UPDATE artifacts SET last_accessed_at = ? WHERE hash = ?",
            bindings: [.double(Date().timeIntervalSince1970), .text(hash)]
        )
        return RetrievedArtifact(
            hash: hash,
            text: text(statement, 0),
            metadata: try decodeJSON(text(statement, 1)),
            score: 1
        )
    }

    public func searchArtifacts(query: String, limit: Int) throws -> [RetrievedArtifact] {
        let expression = Self.ftsExpression(query)
        guard !expression.isEmpty else { return [] }
        let statement = try prepare(
            """
            SELECT a.hash, a.text, a.metadata_json, bm25(artifact_fts), a.last_accessed_at
            FROM artifact_fts JOIN artifacts a ON a.hash = artifact_fts.hash
            WHERE artifact_fts MATCH ?
            ORDER BY bm25(artifact_fts), a.last_accessed_at DESC LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(expression), .integer(Int64(max(0, limit)))], to: statement)

        var result: [RetrievedArtifact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(RetrievedArtifact(
                hash: text(statement, 0),
                text: text(statement, 1),
                metadata: try decodeJSON(text(statement, 2)),
                score: -sqlite3_column_double(statement, 3)
            ))
        }
        try checkRead(statement, operation: "search artifacts")
        let now = Date().timeIntervalSince1970
        for artifact in result {
            try execute(
                "UPDATE artifacts SET last_accessed_at = ? WHERE hash = ?",
                bindings: [.double(now), .text(artifact.hash)]
            )
        }
        return result
    }

    public func deleteConversation(id: String) throws {
        try execute("DELETE FROM conversations WHERE id = ?", bindings: [.text(id)])
    }

    public func cacheStats() throws -> ContextCacheStats {
        let statement = try prepare(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(text AS BLOB))), 0), MIN(last_accessed_at), MAX(last_accessed_at) FROM artifacts"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkRead(statement, operation: "read cache stats", allowDone: true)
            return .init(enabled: true, artifactCount: 0, estimatedBytes: 0)
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        return ContextCacheStats(
            enabled: true,
            artifactCount: count,
            estimatedBytes: Int(sqlite3_column_int64(statement, 1)),
            oldestAccessedAt: count == 0 ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            newestAccessedAt: count == 0 ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    public func pruneArtifacts(olderThan date: Date) throws {
        try transaction {
            try execute(
                "DELETE FROM artifact_fts WHERE hash IN (SELECT hash FROM artifacts WHERE last_accessed_at < ?)",
                bindings: [.double(date.timeIntervalSince1970)]
            )
            try execute("DELETE FROM artifacts WHERE last_accessed_at < ?", bindings: [.double(date.timeIntervalSince1970)])
        }
    }

    public func clearArtifactCache() throws {
        try transaction {
            try execute("DELETE FROM artifact_fts")
            try execute("DELETE FROM artifacts")
        }
    }

    public func purgeExpired() throws {
        let cutoff = Date().timeIntervalSince1970 - retentionInterval
        try transaction {
            try execute("DELETE FROM conversations WHERE updated_at < ?", bindings: [.double(cutoff)])
            try execute(
                "DELETE FROM artifact_fts WHERE hash IN (SELECT hash FROM artifacts WHERE last_accessed_at < ?)",
                bindings: [.double(cutoff)]
            )
            try execute("DELETE FROM artifacts WHERE last_accessed_at < ?", bindings: [.double(cutoff)])
        }
    }

    private func readConversation(where clause: String, value: String) throws -> ConversationRecord? {
        let statement = try prepare(
            "SELECT id, protocol_name, fingerprint, turn_hashes_json, parent_conversation_id, updated_at FROM conversations WHERE \(clause) ORDER BY updated_at DESC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(value)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkRead(statement, operation: "read conversation", allowDone: true)
            return nil
        }
        return ConversationRecord(
            id: text(statement, 0),
            protocolName: text(statement, 1),
            fingerprint: text(statement, 2),
            turnHashes: try decodeJSON(text(statement, 3)),
            parentConversationID: optionalText(statement, 4),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private static func migrate(db: OpaquePointer) throws {
        try rawExecute(db, "PRAGMA journal_mode=WAL")
        try rawExecute(db, "PRAGMA foreign_keys=ON")
        let version = try userVersion(db)
        if version == 1 {
            try migrateV1ToV2(db)
            return
        }
        try rawExecute(db, """
            CREATE TABLE IF NOT EXISTS conversations(
              id TEXT PRIMARY KEY,
              protocol_name TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              turn_hashes_json TEXT NOT NULL,
              parent_conversation_id TEXT,
              capsule_json TEXT,
              updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS conversations_fingerprint ON conversations(fingerprint, updated_at DESC);
            CREATE TABLE IF NOT EXISTS turns(
              id TEXT NOT NULL,
              conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
              ordinal INTEGER NOT NULL,
              kind TEXT NOT NULL,
              text TEXT NOT NULL,
              source_turn_id TEXT,
              metadata_json TEXT NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY(conversation_id, id),
              UNIQUE(conversation_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS artifacts(
              hash TEXT PRIMARY KEY,
              text TEXT NOT NULL,
              metadata_json TEXT NOT NULL,
              created_at REAL NOT NULL,
              last_accessed_at REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS artifact_fts USING fts5(hash UNINDEXED, text, metadata);
            PRAGMA user_version=2;
            """)
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ContextLedgerError.sqlite(operation: "read schema version", message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ContextLedgerError.sqlite(operation: "read schema version", message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func migrateV1ToV2(_ db: OpaquePointer) throws {
        try rawExecute(db, """
            PRAGMA foreign_keys=OFF;
            BEGIN IMMEDIATE;
            ALTER TABLE conversations ADD COLUMN parent_conversation_id TEXT;
            ALTER TABLE turns RENAME TO turns_v1;
            CREATE TABLE turns(
              id TEXT NOT NULL,
              conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
              ordinal INTEGER NOT NULL,
              kind TEXT NOT NULL,
              text TEXT NOT NULL,
              source_turn_id TEXT,
              metadata_json TEXT NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY(conversation_id, id),
              UNIQUE(conversation_id, ordinal)
            );
            INSERT INTO turns SELECT id, conversation_id, ordinal, kind, text, source_turn_id, metadata_json, created_at FROM turns_v1;
            DROP TABLE turns_v1;
            PRAGMA user_version=2;
            COMMIT;
            PRAGMA foreign_keys=ON;
            """)
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case double(Double)
        case null
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error(operation: "execute")
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(operation: "prepare")
        }
        return statement
    }

    private func bind(_ values: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw error(operation: "bind") }
        }
    }

    private func checkRead(_ statement: OpaquePointer, operation: String, allowDone: Bool = false) throws {
        let code = sqlite3_errcode(db)
        if code != SQLITE_OK && code != SQLITE_DONE && code != SQLITE_ROW {
            throw error(operation: operation)
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        do {
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            throw ContextLedgerError.encoding(String(describing: error))
        }
    }

    private func decodeJSON<T: Decodable>(_ value: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: Data(value.utf8))
        } catch {
            throw ContextLedgerError.encoding(String(describing: error))
        }
    }

    private func error(operation: String) -> ContextLedgerError {
        .sqlite(operation: operation, message: String(cString: sqlite3_errmsg(db)))
    }

    private static func rawExecute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw ContextLedgerError.sqlite(operation: "migration", message: detail)
        }
    }

    private static func ftsExpression(_ query: String) -> String {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." && $0 != "/" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
