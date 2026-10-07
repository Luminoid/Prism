import os

// MARK: - ExampleLog

/// The Example's own log channels. Prism writes under `dev.luminoid.prism`; these lines go
/// under `dev.luminoid.prism.example`, so Console can show either or both:
/// `/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "dev.luminoid.prism"'`.
///
/// Errors are logged with `String(describing:)` (the enum case and its payload), never
/// `localizedDescription`, which is for the toast.
enum ExampleLog {
    /// Boot, mode changes, device hops.
    static let session = Logger(subsystem: subsystem, category: "Session")
    /// Shutter, captures, saves.
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    /// Errors shown to the user, through ``ToastPresenter/report(_:context:)``.
    static let ui = Logger(subsystem: subsystem, category: "UI")

    private static let subsystem = "dev.luminoid.prism.example"
}
