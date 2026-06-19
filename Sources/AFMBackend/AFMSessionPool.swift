import Foundation
import FoundationModels

public struct AFMSessionPoolConfiguration: Sendable, Equatable {
    public let maximumSessions: Int
    public let ttl: TimeInterval

    public init(maximumSessions: Int = 32, ttl: TimeInterval = 1_800) {
        self.maximumSessions = max(1, maximumSessions)
        self.ttl = max(1, ttl)
    }
}

public struct AFMSessionPoolStats: Sendable, Equatable {
    public let activeSessions: Int
    public let hits: Int
    public let misses: Int
    public let evictions: Int
}

public actor AFMSessionPool {
    private struct Entry {
        let session: LanguageModelSession
        let fingerprint: String
        var lastUsed: Date
    }

    private let model: SystemLanguageModel
    private let configuration: AFMSessionPoolConfiguration
    private var entries: [String: Entry] = [:]
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var hitCount = 0
    private var missCount = 0
    private var evictionCount = 0

    public init(
        model: SystemLanguageModel = .default,
        configuration: AFMSessionPoolConfiguration = .init()
    ) {
        self.model = model
        self.configuration = configuration
    }

    public func respond(
        key: String,
        fingerprint: String,
        instructions: String,
        fullPrompt: String,
        incrementalPrompt: String?,
        options: GenerationOptions
    ) async throws -> String {
        await acquire(key)
        defer { release(key) }
        evictExpired()

        let now = Date()
        let entry: Entry
        let prompt: String
        if var existing = entries[key], existing.fingerprint == fingerprint {
            hitCount += 1
            existing.lastUsed = now
            entries[key] = existing
            entry = existing
            prompt = incrementalPrompt.flatMap { $0.isEmpty ? nil : $0 } ?? fullPrompt
        } else {
            missCount += 1
            let session = instructions.isEmpty
                ? LanguageModelSession(model: model)
                : LanguageModelSession(model: model, instructions: instructions)
            entry = Entry(session: session, fingerprint: fingerprint, lastUsed: now)
            entries[key] = entry
            evictLRUIfNeeded(excluding: key)
            prompt = fullPrompt
        }

        let response = try await entry.session.respond(to: prompt, options: options)
        if var current = entries[key] {
            current.lastUsed = Date()
            entries[key] = current
        }
        return response.content
    }

    public func invalidate(_ key: String) {
        entries.removeValue(forKey: key)
    }

    public func removeAll() {
        entries.removeAll()
    }

    public func stats() -> AFMSessionPoolStats {
        AFMSessionPoolStats(
            activeSessions: entries.count,
            hits: hitCount,
            misses: missCount,
            evictions: evictionCount
        )
    }

    private func acquire(_ key: String) async {
        if !busy.contains(key) {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            busy.remove(key)
        }
    }

    private func evictExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-configuration.ttl)
        let expired = entries.filter { !busy.contains($0.key) && $0.value.lastUsed < cutoff }.map(\.key)
        for key in expired {
            entries.removeValue(forKey: key)
            evictionCount += 1
        }
    }

    private func evictLRUIfNeeded(excluding protectedKey: String) {
        while entries.count > configuration.maximumSessions {
            guard let victim = entries
                .filter({ $0.key != protectedKey && !busy.contains($0.key) })
                .min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
            entries.removeValue(forKey: victim)
            evictionCount += 1
        }
    }
}
