// MARK: - LatestWinsRunner

/// Runs camera calls from controls one at a time per key, newest value first.
///
/// Each ``run(_:_:)`` waits for the previous call under the same key and cancels it if it
/// hasn't started yet, so a slider drag lands its values in order and only the most recent
/// pending one runs: a 60 Hz drag never queues dozens of actor hops behind each other. A
/// call that has already started finishes (camera setters don't stop half-way).
///
/// Every task is stored, and ``cancelAll()`` (on disappear) or `deinit` cancels them.
@MainActor
final class LatestWinsRunner {
    // MARK: - Properties

    private var tasks: [String: Task<Void, Never>] = [:]

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
        let previous = tasks[key]
        previous?.cancel()
        tasks[key] = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    /// Cancels every queued call; calls already running finish.
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}
