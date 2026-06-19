import Foundation

enum DeltaStreamer {
    /// Returns the incremental text added going from `previous` to `current`.
    /// AFM streams cumulative snapshots; Anthropic SSE expects incremental deltas.
    /// If `current` does not extend `previous`, the full `current` is returned (reset case).
    static func delta(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }
}

