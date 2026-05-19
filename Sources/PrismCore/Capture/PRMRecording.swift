import CoreMedia
import Foundation

/// The result of a completed video recording.
public struct PRMRecording: Sendable, Equatable {
    /// File URL of the recorded `.mov`.
    public let url: URL

    /// Approximate duration of the recording.
    public let duration: TimeInterval

    public init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }
}
