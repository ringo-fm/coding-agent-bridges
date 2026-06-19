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
    public let updatedAt: Date

    public init(
        id: String,
        protocolName: String,
        fingerprint: String,
        turnHashes: [String],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.protocolName = protocolName
        self.fingerprint = fingerprint
        self.turnHashes = turnHashes
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

public protocol ContextLedger: Sendable {
    func saveConversation(_ conversation: ConversationRecord) async throws
    func conversation(id: String) async throws -> ConversationRecord?
    func conversation(fingerprint: String) async throws -> ConversationRecord?
    func append(_ segment: ContextSegment, to conversationID: String) async throws
    func segments(for conversationID: String, limit: Int) async throws -> [ContextSegment]
    func saveCapsule(_ capsule: ContextCapsule, for conversationID: String) async throws
    func capsule(for conversationID: String) async throws -> ContextCapsule?
    func cacheArtifact(hash: String, text: String, metadata: [String: String]) async throws
    func artifact(hash: String) async throws -> RetrievedArtifact?
    func searchArtifacts(query: String, limit: Int) async throws -> [RetrievedArtifact]
    func purgeExpired() async throws
}

public actor InMemoryContextLedger: ContextLedger {
    private var conversations: [String: ConversationRecord] = [:]
    private var conversationByFingerprint: [String: String] = [:]
    private var storedSegments: [String: [ContextSegment]] = [:]
    private var capsules: [String: ContextCapsule] = [:]
    private var artifacts: [String: RetrievedArtifact] = [:]
    private let retentionInterval: TimeInterval

    public init(retentionDays: Int = 30) {
        retentionInterval = TimeInterval(max(1, retentionDays) * 86_400)
    }

    public func saveConversation(_ conversation: ConversationRecord) {
        conversations[conversation.id] = conversation
        conversationByFingerprint[conversation.fingerprint] = conversation.id
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
    }

    public func artifact(hash: String) -> RetrievedArtifact? { artifacts[hash] }

    public func searchArtifacts(query: String, limit: Int) -> [RetrievedArtifact] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return artifacts.values.compactMap { artifact in
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
    }
}

public actor DisabledContextLedger: ContextLedger {
    public init() {}
    public func saveConversation(_: ConversationRecord) {}
    public func conversation(id _: String) -> ConversationRecord? { nil }
    public func conversation(fingerprint _: String) -> ConversationRecord? { nil }
    public func append(_: ContextSegment, to _: String) {}
    public func segments(for _: String, limit _: Int) -> [ContextSegment] { [] }
    public func saveCapsule(_: ContextCapsule, for _: String) {}
    public func capsule(for _: String) -> ContextCapsule? { nil }
    public func cacheArtifact(hash _: String, text _: String, metadata _: [String: String]) {}
    public func artifact(hash _: String) -> RetrievedArtifact? { nil }
    public func searchArtifacts(query _: String, limit _: Int) -> [RetrievedArtifact] { [] }
    public func purgeExpired() {}
}
