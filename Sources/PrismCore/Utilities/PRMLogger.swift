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
public enum PRMLogger: Sendable {
    private static let subsystem = "com.luminoid.Prism"

    /// Returns a cached `os.Logger` for the given category.
    public static func logger(for category: PRMLogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    // MARK: - Convenience

    public static let session = logger(for: .session)
    public static let capture = logger(for: .capture)
    public static let filter = logger(for: .filter)
    public static let preview = logger(for: .preview)
    public static let general = logger(for: .general)
}
