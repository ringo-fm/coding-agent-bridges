import Foundation

/// In-memory store of completed response objects, keyed by response id.
/// Backs `GET /v1/responses/{id}`. Entries expire after `ttlSeconds` to bound
/// memory usage in long-running daemons.
public actor ResponseStore {
    private struct Entry {
        let response: ResponsesResponse
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttlSeconds: TimeInterval

    public init(ttlSeconds: TimeInterval = 3600) {
        self.ttlSeconds = ttlSeconds
    }

    public func store(_ response: ResponsesResponse) {
        evict()
        entries[response.id] = Entry(response: response, storedAt: Date())
    }

    public func get(_ id: String) -> ResponsesResponse? {
        evict()
        guard let entry = entries[id] else { return nil }
        return entry.response
    }

    private func evict() {
        let cutoff = Date().addingTimeInterval(-ttlSeconds)
        entries = entries.filter { $0.value.storedAt >= cutoff }
    }
}

