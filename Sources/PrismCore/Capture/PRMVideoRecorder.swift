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
    ///
    /// Honors `Task` cancellation: if the surrounding task is cancelled while waiting for the
    /// file output to begin, recording is stopped and the call throws ``PRMSessionError/cancelled``.
    public func start(
        rotationAngle: CGFloat? = nil,
        stabilizationMode: AVCaptureVideoStabilizationMode? = nil
    ) async throws {
        PRMLogger.trace(
            .capture,
            "PRMVideoRecorder.start(rotation=\(rotationAngle.map { String(describing: $0) } ?? "nil"), stab=\(stabilizationMode?.rawValue.description ?? "nil"))"
        )
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

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                startContinuation = continuation
                state = .recording(url: url, startedAt: Date())
                lock.unlock()
                output.startRecording(to: url, recordingDelegate: self)
            }
        } onCancel: { [weak self] in
            self?.output.stopRecording()
        }
    }

    /// Stops recording. Returns when the file is finalized.
    ///
    /// Honors `Task` cancellation: cancellation during finalization does NOT abort writing
    /// (the file is already being flushed by AVFoundation) — the call still resumes when the
    /// delegate fires, so the caller gets the partial recording. Use ``cancel()`` to discard.
    public func stop() async throws -> PRMRecording {
        PRMLogger.trace(.capture, "PRMVideoRecorder.stop")
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

    /// Stops recording and discards the file. Use when the user aborts mid-recording.
    public func cancel() {
        guard case let .recording(url, _) = state else { return }
        output.stopRecording()
        PRMTempFile.remove(url)
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
