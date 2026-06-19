import Foundation

public enum ContextStorageMode: String, Codable, Sendable, CaseIterable {
    case off
    case memory
    case persistent

    public init(environmentValue: String?) {
        self = environmentValue.flatMap(Self.init(rawValue:)) ?? .memory
    }
}

public struct ConversationRecord: Codable, Sendable, Equatable {
    public let id: String
    public let protocolName: String
    public let fingerprint: String
    public let turnHashes: [String]
    public let parentConversationID: String?
    public let updatedAt: Date

    public init(
        id: String,
        protocolName: String,
        fingerprint: String,
        turnHashes: [String],
        parentConversationID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.protocolName = protocolName
        self.fingerprint = fingerprint
        self.turnHashes = turnHashes
        self.parentConversationID = parentConversationID
        self.updatedAt = updatedAt
    }
}

public struct RetrievedArtifact: Codable, Sendable, Equatable {
    public let hash: String
    public let text: String
    public let metadata: [String: String]
    public let score: Double

    public init(hash: String, text: String, metadata: [String: String], score: Double) {
        self.hash = hash
        self.text = text
        self.metadata = metadata
        self.score = score
    }
}

public struct ContextStorageStatus: Codable, Sendable, Equatable {
    public let mode: ContextStorageMode
    public let enabled: Bool
    public let path: String?

    public init(mode: ContextStorageMode, path: String? = nil) {
        self.mode = mode
        enabled = mode != .off
        self.path = path
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public let id: String
    public let protocolName: String
    public let updatedAt: Date
    public let parentConversationID: String?
    public let turnCount: Int
    public let segmentCount: Int
    public let hasCapsule: Bool
}

public struct SessionDetail: Codable, Sendable, Equatable {
    public let summary: SessionSummary
    public let fingerprint: String
    public let turnHashes: [String]

    public init(summary: SessionSummary, fingerprint: String, turnHashes: [String]) {
        self.summary = summary
        self.fingerprint = fingerprint
        self.turnHashes = turnHashes
    }
}

public struct SessionExport: Codable, Sendable, Equatable {
    public let conversation: ConversationRecord
    public let segments: [ContextSegment]
    public let capsule: ContextCapsule?
    public let includesContent: Bool

    public init(conversation: ConversationRecord, segments: [ContextSegment], capsule: ContextCapsule?, includesContent: Bool) {
        self.conversation = conversation
        self.segments = segments
        self.capsule = capsule
        self.includesContent = includesContent
    }
}

public struct SessionResumeBundle: Codable, Sendable, Equatable {
    public let conversation: ConversationRecord
    public let recentSegments: [ContextSegment]
    public let capsule: ContextCapsule?

    public init(conversation: ConversationRecord, recentSegments: [ContextSegment], capsule: ContextCapsule?) {
        self.conversation = conversation
        self.recentSegments = recentSegments
        self.capsule = capsule
    }
}

public struct ContextCacheStats: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let artifactCount: Int
    public let estimatedBytes: Int?
    public let oldestAccessedAt: Date?
    public let newestAccessedAt: Date?

    public init(
        enabled: Bool,
        artifactCount: Int,
        estimatedBytes: Int? = nil,
        oldestAccessedAt: Date? = nil,
        newestAccessedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.artifactCount = artifactCount
        self.estimatedBytes = estimatedBytes
        self.oldestAccessedAt = oldestAccessedAt
        self.newestAccessedAt = newestAccessedAt
    }
}

public protocol ContextLedger: Sendable {
    func storageStatus() async -> ContextStorageStatus
    func saveConversation(_ conversation: ConversationRecord) async throws
    func listConversations(limit: Int) async throws -> [SessionSummary]
    func conversation(id: String) async throws -> ConversationRecord?
    func conversation(fingerprint: String) async throws -> ConversationRecord?
    func append(_ segment: ContextSegment, to conversationID: String) async throws
    func segments(for conversationID: String, limit: Int) async throws -> [ContextSegment]
    func saveCapsule(_ capsule: ContextCapsule, for conversationID: String) async throws
    func capsule(for conversationID: String) async throws -> ContextCapsule?
    func cacheArtifact(hash: String, text: String, metadata: [String: String]) async throws
    func artifact(hash: String) async throws -> RetrievedArtifact?
    func searchArtifacts(query: String, limit: Int) async throws -> [RetrievedArtifact]
    func deleteConversation(id: String) async throws
    func cacheStats() async throws -> ContextCacheStats
    func pruneArtifacts(olderThan date: Date) async throws
    func clearArtifactCache() async throws
    func purgeExpired() async throws
}

public actor InMemoryContextLedger: ContextLedger {
    private var conversations: [String: ConversationRecord] = [:]
    private var conversationByFingerprint: [String: String] = [:]
    private var storedSegments: [String: [ContextSegment]] = [:]
    private var capsules: [String: ContextCapsule] = [:]
    private var artifacts: [String: RetrievedArtifact] = [:]
    private var artifactAccessedAt: [String: Date] = [:]
    private let retentionInterval: TimeInterval

    public init(retentionDays: Int = 30) {
        retentionInterval = TimeInterval(max(1, retentionDays) * 86_400)
    }

    public func storageStatus() -> ContextStorageStatus { .init(mode: .memory) }

    public func saveConversation(_ conversation: ConversationRecord) {
        conversations[conversation.id] = conversation
        conversationByFingerprint[conversation.fingerprint] = conversation.id
    }

    public func listConversations(limit: Int) -> [SessionSummary] {
        conversations.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit)).map { conversation in
            SessionSummary(
                id: conversation.id,
                protocolName: conversation.protocolName,
                updatedAt: conversation.updatedAt,
                parentConversationID: conversation.parentConversationID,
                turnCount: conversation.turnHashes.count,
                segmentCount: storedSegments[conversation.id, default: []].count,
                hasCapsule: capsules[conversation.id] != nil
            )
        }
    }

    public func conversation(id: String) -> ConversationRecord? { conversations[id] }

    public func conversation(fingerprint: String) -> ConversationRecord? {
        conversationByFingerprint[fingerprint].flatMap { conversations[$0] }
    }

    public func append(_ segment: ContextSegment, to conversationID: String) {
        if storedSegments[conversationID, default: []].contains(where: { $0.id == segment.id }) { return }
        storedSegments[conversationID, default: []].append(segment)
    }

    public func segments(for conversationID: String, limit: Int) -> [ContextSegment] {
        Array(storedSegments[conversationID, default: []].suffix(max(0, limit)))
    }

    public func saveCapsule(_ capsule: ContextCapsule, for conversationID: String) {
        capsules[conversationID] = capsule
    }

    public func capsule(for conversationID: String) -> ContextCapsule? { capsules[conversationID] }

    public func cacheArtifact(hash: String, text: String, metadata: [String: String]) {
        artifacts[hash] = RetrievedArtifact(hash: hash, text: text, metadata: metadata, score: 0)
        artifactAccessedAt[hash] = Date()
    }

    public func artifact(hash: String) -> RetrievedArtifact? {
        if artifacts[hash] != nil { artifactAccessedAt[hash] = Date() }
        return artifacts[hash]
    }

    public func searchArtifacts(query: String, limit: Int) -> [RetrievedArtifact] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }
        let result: [RetrievedArtifact] = artifacts.values.compactMap { artifact -> RetrievedArtifact? in
            let haystack = (artifact.text + " " + artifact.metadata.values.joined(separator: " ")).lowercased()
            let matches = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            guard matches > 0 else { return nil }
            return RetrievedArtifact(
                hash: artifact.hash,
                text: artifact.text,
                metadata: artifact.metadata,
                score: Double(matches) / Double(terms.count)
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(max(0, limit))
        .map { $0 }
        let now = Date()
        for artifact in result { artifactAccessedAt[artifact.hash] = now }
        return result
    }

    public func deleteConversation(id: String) {
        if let fingerprint = conversations[id]?.fingerprint {
            conversationByFingerprint.removeValue(forKey: fingerprint)
        }
        conversations.removeValue(forKey: id)
        storedSegments.removeValue(forKey: id)
        capsules.removeValue(forKey: id)
    }

    public func cacheStats() -> ContextCacheStats {
        ContextCacheStats(
            enabled: true,
            artifactCount: artifacts.count,
            estimatedBytes: artifacts.values.reduce(0) { $0 + $1.text.utf8.count },
            oldestAccessedAt: artifactAccessedAt.values.min(),
            newestAccessedAt: artifactAccessedAt.values.max()
        )
    }

    public func pruneArtifacts(olderThan date: Date) {
        for hash in artifactAccessedAt.filter({ $0.value < date }).map(\.key) {
            artifacts.removeValue(forKey: hash)
            artifactAccessedAt.removeValue(forKey: hash)
        }
    }

    public func clearArtifactCache() {
        artifacts.removeAll()
        artifactAccessedAt.removeAll()
    }

    public func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        let expired = conversations.values.filter { $0.updatedAt < cutoff }.map(\.id)
        for id in expired {
            if let fingerprint = conversations[id]?.fingerprint {
                conversationByFingerprint.removeValue(forKey: fingerprint)
            }
            conversations.removeValue(forKey: id)
            storedSegments.removeValue(forKey: id)
            capsules.removeValue(forKey: id)
        }
        pruneArtifacts(olderThan: cutoff)
    }
}

public actor DisabledContextLedger: ContextLedger {
    public init() {}
    public func storageStatus() -> ContextStorageStatus { .init(mode: .off) }
    public func saveConversation(_: ConversationRecord) {}
    public func listConversations(limit _: Int) -> [SessionSummary] { [] }
    public func conversation(id _: String) -> ConversationRecord? { nil }
    public func conversation(fingerprint _: String) -> ConversationRecord? { nil }
    public func append(_: ContextSegment, to _: String) {}
    public func segments(for _: String, limit _: Int) -> [ContextSegment] { [] }
    public func saveCapsule(_: ContextCapsule, for _: String) {}
    public func capsule(for _: String) -> ContextCapsule? { nil }
    public func cacheArtifact(hash _: String, text _: String, metadata _: [String: String]) {}
    public func artifact(hash _: String) -> RetrievedArtifact? { nil }
    public func searchArtifacts(query _: String, limit _: Int) -> [RetrievedArtifact] { [] }
    public func deleteConversation(id _: String) {}
    public func cacheStats() -> ContextCacheStats { .init(enabled: false, artifactCount: 0, estimatedBytes: 0) }
    public func pruneArtifacts(olderThan _: Date) {}
    public func clearArtifactCache() {}
    public func purgeExpired() {}
}
