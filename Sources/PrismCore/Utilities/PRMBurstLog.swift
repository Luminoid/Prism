import Foundation

/// Debug lines for slider-rate calls, one pair per burst instead of one per tick (a slider drag
/// otherwise logs 40 to 80 lines): the first call of a burst at once, then, once calls under
/// the same key stop for ``quietInterval``, the value they settled on and how many came
/// between. Repeats of the logged text are dropped.
@MainActor
final class PRMBurstLog {
    private struct Burst {
        var first: String
        var latest: String
        var count: Int
        var flush: Task<Void, Never>?
    }

    /// How long calls under one key must stop before the burst closes.
    let quietInterval: Duration
    private var bursts: [String: Burst] = [:]

    init(quietInterval: Duration = .milliseconds(500)) {
        self.quietInterval = quietInterval
    }

    isolated deinit {
        for burst in bursts.values {
            burst.flush?.cancel()
        }
    }

    /// Logs `message` at debug when it opens a burst for `key`; otherwise records it as the
    /// burst's latest value.
    func record(_ key: String, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard PRMLog.isLogging(.debug) else { return }
        let text = message()
        guard var burst = bursts[key] else {
            PRMLog.debug(.session, text, file: file, line: line)
            bursts[key] = Burst(first: text, latest: text, count: 0, flush: scheduleClose(key, file: file, line: line))
            return
        }
        burst.flush?.cancel()
        if text != burst.latest {
            burst.latest = text
            burst.count += 1
        }
        burst.flush = scheduleClose(key, file: file, line: line)
        bursts[key] = burst
    }

    /// The closing line for a burst: `nil` when nothing changed after its first call.
    nonisolated static func closingLine(first: String, latest: String, count: Int) -> String? {
        guard count > 0, latest != first else { return nil }
        return "\(latest) (settled after \(count) more)"
    }

    private func scheduleClose(_ key: String, file: String, line: Int) -> Task<Void, Never> {
        Task { [weak self, quietInterval] in
            try? await Task.sleep(for: quietInterval)
            guard !Task.isCancelled else { return }
            self?.close(key, file: file, line: line)
        }
    }

    private func close(_ key: String, file: String, line: Int) {
        guard let burst = bursts.removeValue(forKey: key),
              let closing = Self.closingLine(first: burst.first, latest: burst.latest, count: burst.count)
        else { return }
        PRMLog.debug(.session, closing, file: file, line: line)
    }
}
