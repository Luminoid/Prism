import os

// MARK: - PRMLogCategory

/// Log categories for Prism subsystems.
public enum PRMLogCategory: String, Sendable {
    case session = "Session"
    case capture = "Capture"
    case filter = "Filter"
    case preview = "Preview"
    case general = "General"
}

// MARK: - PRMLogger

/// Lightweight `os.Logger` wrapper for structured logging across Prism subsystems.
///
/// `os.Logger` is thread-safe by Apple's documentation — internally backed by a
/// lock-free ring buffer with mutex-protected coalescing. All Prism subsystems
/// (camera actor, data-output queue, MainActor view controllers, background
/// continuations) log through the same `Logger` instances without coordination.
///
/// **Verbose tracing**: scene/lifecycle traces inside the SDK (`configure`,
/// `start`/`stop`, `switchCamera`, every exposure / WB / zoom setter, every
/// `applyPhotoFormat` / `restoreBaselineFormat`, etc.) are gated behind
/// ``isVerboseTracingEnabled``. They emit at `.notice` so they show up under
/// the default Console.app filter when enabled, and produce no log calls
/// whatsoever when disabled (the guard is a single Bool read with no
/// string interpolation). Off by default to keep release builds quiet;
/// flip on from the consuming app (e.g. example's `viewDidLoad`) for
/// debugging or repro capture.
public enum PRMLogger: Sendable {
    private static let subsystem = "com.luminoid.Prism"

    /// Returns a cached `os.Logger` for the given category. Marked `nonisolated`
    /// for clarity — the function has no actor isolation and is safe to call from
    /// any context (it returns a new `Logger` value, which is itself `Sendable`).
    public nonisolated static func logger(for category: PRMLogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    // MARK: - Convenience

    public static let session = logger(for: .session)
    public static let capture = logger(for: .capture)
    public static let filter = logger(for: .filter)
    public static let preview = logger(for: .preview)
    public static let general = logger(for: .general)

    // MARK: - Verbose tracing

    /// Master switch for verbose SDK traces. Off by default. Flip from the
    /// consuming app to capture configure / switch / setter / format-swap /
    /// capture-lifecycle traces. Read on the hot path of every `trace*` call
    /// — a single relaxed-atomic-style Bool read; `nonisolated(unsafe)`
    /// because `os.Logger` is already thread-safe and toggling at runtime
    /// from any thread is intentional. Setting the flag is meant to be
    /// idempotent from any caller; concurrent toggles produce one of the
    /// two values with no torn write.
    public nonisolated(unsafe) static var isVerboseTracingEnabled: Bool = false

    /// Emit a verbose trace line on the given category. No-ops (and skips
    /// string interpolation) when ``isVerboseTracingEnabled`` is false.
    ///
    /// Callers pass the message via an autoclosure so interpolation cost is
    /// paid only when tracing is on. Emits at `.notice` so the default
    /// Console.app filter shows it without dropping to `.debug`.
    @inlinable
    public nonisolated static func trace(
        _ category: PRMLogCategory,
        _ message: @autoclosure () -> String
    ) {
        guard isVerboseTracingEnabled else { return }
        let rendered = message()
        logger(for: category).notice("[trace] \(rendered, privacy: .public)")
    }
}
