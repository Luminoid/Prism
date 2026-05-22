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
}
