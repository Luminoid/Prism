import AVFoundation
import Foundation

/// Async-await wrapper for `AVCaptureMovieFileOutput`.
///
/// ```swift
/// let recorder = PRMVideoRecorder(output: movieFileOutput)
/// try await recorder.start(rotationAngle: 90)
/// // ... user records ...
/// let recording = try await recorder.stop()  // returns PRMRecording with URL + duration
/// ```
public final class PRMVideoRecorder: NSObject, @unchecked Sendable {
    // MARK: - State

    /// Recording state.
    public enum State: Sendable, Equatable {
        case idle
        case recording(url: URL, startedAt: Date)
        case finalizing
    }

    public let output: AVCaptureMovieFileOutput
    public private(set) var state: State = .idle

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<PRMRecording, Error>?

    private let lock = NSLock()

    // MARK: - Init

    public init(output: AVCaptureMovieFileOutput) {
        self.output = output
        super.init()
    }

    // MARK: - Start / Stop

    /// Starts recording to a new tmp file. Returns when the file output has actually begun.
    public func start(
        rotationAngle: CGFloat? = nil,
        stabilizationMode: AVCaptureVideoStabilizationMode? = nil
    ) async throws {
        if case .recording = state { return }

        let url = PRMTempFile.url(withExtension: "mov")
        if let connection = output.connection(with: .video) {
            if let rotationAngle, connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            if let stabilizationMode {
                connection.prm_setStabilization(stabilizationMode)
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            startContinuation = continuation
            state = .recording(url: url, startedAt: Date())
            lock.unlock()
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stops recording. Returns when the file is finalized.
    public func stop() async throws -> PRMRecording {
        guard case .recording = state else {
            throw PRMSessionError.videoRecordingFailed("Not currently recording")
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            stopContinuation = continuation
            state = .finalizing
            lock.unlock()
            output.stopRecording()
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension PRMVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        lock.lock()
        let continuation = stopContinuation
        stopContinuation = nil
        let startedAt: Date? = if case let .recording(_, started) = state { started } else { nil }
        state = .idle
        lock.unlock()

        if let error {
            continuation?.resume(throwing: PRMSessionError.videoRecordingFailed(error.localizedDescription))
            return
        }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        continuation?.resume(returning: PRMRecording(url: outputFileURL, duration: duration))
    }
}
