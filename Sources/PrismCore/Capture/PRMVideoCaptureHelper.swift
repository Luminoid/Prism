import AVFoundation
import os
#if canImport(UIKit)
    import UIKit
#endif

/// The current state of the video recording helper.
public enum PRMVideoRecordingState: Sendable, Equatable {
    /// Not currently recording.
    case idle
    /// Recording is in progress.
    case recording
    /// Recording has stopped and is being finalized.
    case finalizing
}

/// Manages video recording lifecycle with optional filtered export.
///
/// Does **not** save to the photo library — delivers the output file URL to the consumer.
///
/// ```swift
/// let helper = PRMVideoCaptureHelper()
/// helper.startRecording(to: movieFileOutput, sessionQueue: sessionQueue)
/// // ...
/// helper.stopRecording(to: movieFileOutput) { url in
///     // Do something with the recorded video URL
/// }
/// ```
public final class PRMVideoCaptureHelper: NSObject, @unchecked Sendable {
    // MARK: - Properties

    /// The current recording state.
    public private(set) var state: PRMVideoRecordingState = .idle

    /// Called when recording starts.
    public var onRecordingStarted: (() -> Void)?

    /// Called when recording finishes with the output file URL (or error).
    public var onRecordingFinished: ((_ outputURL: URL?, _ error: Error?) -> Void)?

    /// The output file URL for the current/last recording.
    public private(set) var outputURL: URL?

    // MARK: - Recording

    /// Starts recording to a movie file output.
    ///
    /// Call this on the session queue. Capture the video rotation angle on the main thread
    /// before dispatching to the session queue (e.g., via ``currentVideoRotationAngle()``).
    ///
    /// - Parameters:
    ///   - movieFileOutput: The configured `AVCaptureMovieFileOutput`.
    ///   - connection: The video connection to use. If `nil`, uses the output's first video connection.
    ///   - videoRotationAngle: The rotation angle to apply. Defaults to portrait (90°).
    public func startRecording(
        to movieFileOutput: AVCaptureMovieFileOutput,
        connection: AVCaptureConnection? = nil,
        videoRotationAngle: CGFloat = PRMVideoRotationAngle.portrait,
    ) {
        guard state == .idle else {
            PRMLogger.capture.warning("Cannot start recording: already in state \(String(describing: self.state))")
            return
        }

        let url = PRMFileHelper.temporaryFileURL(withExtension: "mov")
        outputURL = url

        if let connection = connection ?? movieFileOutput.connection(with: .video) {
            connection.prm_setVideoRotationAngle(videoRotationAngle)
        }

        movieFileOutput.startRecording(to: url, recordingDelegate: self)
        state = .recording
    }

    /// Stops the current recording.
    ///
    /// - Parameter movieFileOutput: The movie file output to stop.
    public func stopRecording(to movieFileOutput: AVCaptureMovieFileOutput) {
        guard state == .recording else {
            PRMLogger.capture.warning("Cannot stop recording: not currently recording")
            return
        }
        state = .finalizing
        movieFileOutput.stopRecording()
    }

    // MARK: - Orientation

    /// Returns the current video rotation angle based on device orientation.
    ///
    /// Must be called on the main thread. Capture the result before dispatching
    /// to the session queue for ``startRecording(to:connection:videoRotationAngle:)``.
    @MainActor
    public func currentVideoRotationAngle() -> CGFloat {
        #if canImport(UIKit)
            UIDevice.current.orientation.prm_videoRotationAngle ?? PRMVideoRotationAngle.portrait
        #else
            PRMVideoRotationAngle.landscapeRight
        #endif
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension PRMVideoCaptureHelper: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection],
    ) {
        PRMLogger.capture.info("Recording started: \(fileURL.lastPathComponent)")
        onRecordingStarted?()
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?,
    ) {
        state = .idle

        if let error {
            PRMLogger.capture.error("Recording error: \(error.localizedDescription)")
            onRecordingFinished?(nil, error)
        } else {
            PRMLogger.capture.info("Recording finished: \(outputFileURL.lastPathComponent)")
            onRecordingFinished?(outputFileURL, nil)
        }
    }
}
