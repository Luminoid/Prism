import Foundation

/// Thread-safe `AsyncStream<Element>` continuation registry.
///
/// Consolidates the UUID-keyed dictionary + `onTermination` cleanup + fan-out yield
/// pattern that several types in PrismCore would otherwise reimplement (the camera
/// state / error / interruption streams on ``PRMCamera``, the preview / capture
/// rotation streams on ``PRMRotationCoordinator``, and the frame stream on
/// ``PRMFilterPipeline``).
///
/// Usage:
/// ```swift
/// private let states = PRMStreamRegistry<PRMCameraState>()
///
/// public func stateStream() -> AsyncStream<PRMCameraState> {
///     states.makeStream(initial: state)   // pass `nil` for streams that don't yield-on-subscribe
/// }
///
/// // From wherever new values arrive:
/// states.yield(newState)
/// ```
///
/// Cardinality is unbounded; the registry only retains continuations that have an
/// active iterator. The `onTermination` block automatically prunes the dictionary
/// when the consuming task cancels. Callers that build long-lived iteration tasks
/// must still cancel those tasks when their owner deinits — otherwise the
/// continuation stays subscribed and keeps receiving values until the registry
/// itself goes away.
///
/// The registry is `@unchecked Sendable` because its only mutable state
/// (`continuations`) is fully guarded by an internal `NSLock`. Used from both
/// `@MainActor` types and free / actor-isolated types interchangeably.
public final class PRMStreamRegistry<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    public init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }

    deinit {
        // Don't leave consumers hanging on `for await x in registry.makeStream()` if the
        // registry is deallocated mid-iteration.
        lock.lock()
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.finish()
        }
    }

    /// Number of currently-registered continuations. Primarily for tests.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    /// Returns a fresh `AsyncStream<Element>` and registers its continuation.
    ///
    /// - Parameter initial: When non-nil, yielded immediately on subscribe. Use for
    ///   "current value + updates" streams (e.g. camera state) where the late-binding
    ///   subscriber should see a snapshot rather than wait for the next mutation.
    public func makeStream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [self] continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            if let initial {
                continuation.yield(initial)
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations.removeValue(forKey: id)
                lock.unlock()
            }
        }
    }

    /// Fans `value` out to every currently-subscribed continuation. Safe to call from
    /// any actor or queue.
    public func yield(_ value: Element) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for continuation in snapshot {
            continuation.yield(value)
        }
    }

    /// Finishes every active subscription and clears the registry.
    public func finishAll() {
        lock.lock()
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.finish()
        }
    }
}
