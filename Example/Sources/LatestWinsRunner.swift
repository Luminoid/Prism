// MARK: - LatestWinsRunner

/// Runs camera calls from controls one at a time per key, newest value first.
///
/// Each ``run(_:_:)`` waits for the previous call under the same key and cancels it if it
/// hasn't started yet, so a slider drag lands its values in order and only the most recent
/// pending one runs: a 60 Hz drag never queues dozens of actor hops behind each other. A
/// call that has already started finishes (camera setters don't stop half-way).
///
/// ``run(_:deduplicating:_:)`` also drops a value that repeats the last one sent under its
/// key: a slider snapped to stops reports every tick, most of them the stop it already sent.
///
/// Every task is stored, and ``cancelAll()`` (on disappear) or `deinit` cancels them.
@MainActor
final class LatestWinsRunner {
    // MARK: - Properties

    private var tasks: [String: Task<Void, Never>] = [:]
    /// The last value ``run(_:deduplicating:_:)`` sent per key; any other call under the key
    /// clears it.
    private var lastValues: [String: AnyHashable] = [:]

    // MARK: - Lifecycle

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    // MARK: - Running

    /// Queues `body` behind the previous call for `key`, dropping that call if it hasn't
    /// started.
    func run(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        lastValues[key] = nil
        let previous = tasks[key]
        previous?.cancel()
        tasks[key] = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    /// Like ``run(_:_:)``, but skips the call when `value` is the last one sent under `key`.
    /// Call ``forget(_:)`` when a drag starts, so its first value is sent even if it matches.
    func run(_ key: String, deduplicating value: AnyHashable, _ body: @escaping @MainActor () async -> Void) {
        guard lastValues[key] != value else { return }
        run(key, body)
        lastValues[key] = value
    }

    /// Forgets the last value sent under `key` (a new drag starts).
    func forget(_ key: String) {
        lastValues[key] = nil
    }

    /// Cancels every queued call; calls already running finish.
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        lastValues.removeAll()
    }
}
