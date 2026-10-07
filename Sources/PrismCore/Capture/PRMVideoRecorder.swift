@preconcurrency import AVFoundation
import Foundation

/// Async-await wrapper for `AVCaptureMovieFileOutput`.
///
/// Two initializers are exposed:
///
/// **Session-based (recommended)** — the recorder resolves the *current* movie
/// output from a `PRMCameraSession` at every `start()` call. Survives format swaps
/// (e.g. entering slo-mo mode) that force Prism to detach + re-attach the underlying
/// `AVCaptureMovieFileOutput` instance. Consuming apps don't have to manually
/// re-bind the recorder after such transitions.
///
/// ```swift
/// let recorder = PRMVideoRecorder(session: camera.session)
/// try await recorder.start(rotationAngle: 90)
/// let recording = try await recorder.stop()
/// ```
///
/// **Output-based (legacy)** — keep this only if you have a hand-managed output that
/// will never be replaced during the session's lifetime. Will throw a typed Swift
/// error from `start()` if the bound output is later replaced by AVFoundation.
///
/// ```swift
/// let recorder = PRMVideoRecorder(output: movieFileOutput)
/// ```
public final class PRMVideoRecorder: NSObject, @unchecked Sendable {
    // MARK: - State

    /// Recording state.
    public enum State: Sendable, Equatable {
        case idle
        case recording(url: URL, startedAt: Date)
        case finalizing
    }

    private let resolver: PRMOutputResolver<AVCaptureMovieFileOutput>

    /// The current state. Every transition happens under the recorder's lock, so a start,
    /// stop or cancel racing another sees a consistent value.
    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// The output the recorder was constructed against (legacy init) or — for the
    /// session-based init — the output the last ``start(rotationAngle:stabilizationMode:)``
    /// resolved, `nil` before that. Recording always resolves the live output itself.
    public var output: AVCaptureMovieFileOutput? {
        resolver.latest
    }

    // Guarded by `lock`.
    private var currentState: State = .idle
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var stopContinuation: CheckedContinuation<PRMRecording, any Error>?
    /// Set while a `start()` is resolving its output, so a second one can't overlap it.
    private var isStarting = false
    /// Set when the task awaiting `start()` is cancelled before recording began, so a
    /// finish without a start reports `.cancelled` rather than a failure.
    private var isStartCancelled = false
    /// Set by ``cancel()`` (or a start cancelled after the output began): the finish that
    /// follows deletes the file, since no caller ever receives its URL.
    private var discardsFinishedRecording = false
    /// The recording's start time, kept while `.finalizing` so the finished recording reports its duration.
    private var finalizingStartedAt: Date?
    /// The file being started, recorded or finalized. Finish callbacks for any other file
    /// are stale and leave the state alone.
    private var activeURL: URL?
    /// The output recording to ``activeURL``; stop and cancel go to it.
    private var recordingOutput: AVCaptureMovieFileOutput?

    private let lock = NSLock()

    // MARK: - Init

    /// Legacy init. The recorder is bound to `output` permanently — if AVFoundation
    /// later replaces that output (e.g. on a format-swap-driven re-attach during
    /// slo-mo activation), `start()` will fail with a typed error. Prefer
    /// ``init(session:)`` for any session that may swap formats.
    public init(output: AVCaptureMovieFileOutput) {
        resolver = PRMOutputResolver(fixed: output)
        super.init()
    }

    /// Session-based init. The recorder resolves `session.movieFileOutput` at every
    /// `start()` call, so format-swap-driven output replacements (e.g. Prism's
    /// internal re-attach when transitioning to a 240 fps slo-mo format) are
    /// invisible to the caller — the next `start()` automatically picks up the
    /// fresh output instance.
    ///
    /// `start()` throws ``PRMSessionError/videoRecordingFailed(_:)`` if the session
    /// has no movie output attached at start time (i.e. the consuming app forgot
    /// to call `setMovieFileOutputAttached(true)` for video mode).
    public init(session: PRMCameraSession) {
        resolver = PRMOutputResolver { [weak session] in
            guard let session else { return nil }
            return await session.movieFileOutput
        }
        super.init()
    }

    // MARK: - Start / Stop

    /// Starts recording to a new tmp file. Returns when the file output has actually begun.
    /// A no-op while already recording.
    ///
    /// Honors `Task` cancellation: if the surrounding task is cancelled while waiting for the
    /// file output to begin, recording is stopped and the call throws ``PRMSessionError/cancelled``.
    ///
    /// - Throws: ``PRMSessionError/videoRecordingFailed(_:)`` while the previous recording is
    ///   still finalizing (starting then would make its finish look like this recording's),
    ///   while another `start()` is under way, or when the movie output or its video
    ///   connection is missing; ``PRMSessionError/captureFailed(_:)`` when AVFoundation fails
    ///   the recording before it begins.
    public func start(
        rotationAngle: CGFloat? = nil,
        stabilizationMode: AVCaptureVideoStabilizationMode? = nil
    ) async throws {
        PRMLog.debug(
            .capture,
            "PRMVideoRecorder.start(rotation=\(rotationAngle.map { String(describing: $0) } ?? "nil"), stab=\(stabilizationMode?.rawValue.description ?? "nil"))"
        )
        guard try reserveStart() else { return }
        let url = PRMTempFile.url(withExtension: "mov")
        let resolvedOutput: AVCaptureMovieFileOutput
        do {
            resolvedOutput = try await preparedOutput(rotationAngle: rotationAngle, stabilizationMode: stabilizationMode)
        } catch {
            releaseStartReservation()
            throw error
        }

        try await withTaskCancellationHandler {
            try await waitForRecordingStart(url: url, output: resolvedOutput) {
                resolvedOutput.startRecording(to: url, recordingDelegate: self)
            }
        } onCancel: { [weak self] in
            self?.markStartCancelled()
        }
        PRMLog.notice(.capture, "Recording started", private: url.path)
    }

    /// Claims the start. `false` when already recording (no-op); throws while finalizing or
    /// while another start is under way.
    private nonisolated func reserveStart() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch currentState {
        case .recording:
            return false
        case .finalizing:
            throw PRMSessionError.videoRecordingFailed("The previous recording is still finalizing")
        case .idle:
            guard !isStarting else {
                throw PRMSessionError.videoRecordingFailed("A recording is already starting")
            }
            isStarting = true
            return true
        }
    }

    private nonisolated func releaseStartReservation() {
        lock.lock()
        defer { lock.unlock() }
        isStarting = false
    }

    /// Resolves the live movie output and checks its video connection.
    ///
    /// `startRecording` raises `NSInvalidArgumentException` ("No active/enabled
    /// connections") when the connection is missing or inactive, and an uncaught ObjC
    /// exception in a Swift async context terminates the process. A typed error lets the
    /// app show a "video pipeline not ready" message and reconfigure instead. This covers
    /// the class of bug where another path detached the movie output (a mode-switch race, a
    /// full reconfigure) between the app deciding it's in video mode and the user tapping
    /// record.
    private func preparedOutput(
        rotationAngle: CGFloat?,
        stabilizationMode: AVCaptureVideoStabilizationMode?
    ) async throws -> AVCaptureMovieFileOutput {
        guard let resolvedOutput = await resolver.resolve() else {
            PRMLog.error(.capture, "Recording refused: no movie file output attached to the session")
            throw PRMSessionError.videoRecordingFailed(
                "AVCaptureMovieFileOutput is not attached to the session — call setMovieFileOutputAttached(true) before recording"
            )
        }
        guard let connection = resolvedOutput.connection(with: .video) else {
            PRMLog.error(.capture, "Recording refused: movie file output has no video connection")
            throw PRMSessionError.videoRecordingFailed(
                "AVCaptureMovieFileOutput has no video connection — was the movie output attached to the session?"
            )
        }
        guard connection.isEnabled, connection.isActive else {
            PRMLog.error(
                .capture,
                "Recording refused: movie video connection isEnabled=\(connection.isEnabled), isActive=\(connection.isActive)"
            )
            throw PRMSessionError.videoRecordingFailed(
                "AVCaptureMovieFileOutput connection is not active/enabled — the session may be misconfigured or interrupted"
            )
        }
        if let rotationAngle, connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if let stabilizationMode {
            connection.prm_setStabilization(stabilizationMode)
        }
        return resolvedOutput
    }

    /// Installs the start continuation, calls `begin` (which asks the output to record),
    /// and suspends until the delegate reports the start, or a finish that came first.
    /// Separate from `start()` so tests can drive the delegate without a capture session.
    func waitForRecordingStart(url: URL, output: AVCaptureMovieFileOutput? = nil, begin: () -> Void) async throws {
        // A task cancelled before this point already ran its `onCancel` (finding no
        // continuation to flag), so carry the cancellation in here.
        let alreadyCancelled = Task.isCancelled
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            startContinuation = continuation
            isStartCancelled = alreadyCancelled
            discardsFinishedRecording = false
            isStarting = false
            activeURL = url
            recordingOutput = output ?? resolver.latest
            currentState = .recording(url: url, startedAt: Date())
            lock.unlock()
            begin()
        }
    }

    /// Flags a start whose task was cancelled and stops the output it asked to record.
    private nonisolated func markStartCancelled() {
        lock.lock()
        let pending = startContinuation != nil
        if pending {
            isStartCancelled = true
        }
        let output = recordingOutput
        lock.unlock()
        if pending {
            output?.stopRecording()
        }
    }

    /// Stops recording. Returns when the file is finalized.
    ///
    /// Honors `Task` cancellation: cancellation during finalization does NOT abort writing
    /// (the file is already being flushed by AVFoundation) — the call still resumes when the
    /// delegate fires, so the caller gets the partial recording. Use ``cancel()`` to discard.
    ///
    /// - Throws: ``PRMSessionError/videoRecordingFailed(_:)`` when not recording (including a
    ///   second `stop()` while the first finalizes); ``PRMSessionError/captureFailed(_:)``
    ///   when AVFoundation fails the recording.
    public func stop() async throws -> PRMRecording {
        PRMLog.debug(.capture, "PRMVideoRecorder.stop")
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard case let .recording(_, startedAt) = currentState, stopContinuation == nil else {
                lock.unlock()
                continuation.resume(throwing: PRMSessionError.videoRecordingFailed("Not currently recording"))
                return
            }
            stopContinuation = continuation
            finalizingStartedAt = startedAt
            currentState = .finalizing
            let output = recordingOutput ?? resolver.latest
            lock.unlock()
            output?.stopRecording()
        }
    }

    /// Stops recording and discards the file once AVFoundation has finished writing it. Use
    /// when the user aborts mid-recording. The recorder is `.finalizing` until then, so a
    /// new ``start(rotationAngle:stabilizationMode:)`` waits for the discard instead of
    /// racing it.
    public func cancel() {
        lock.lock()
        guard case .recording = currentState else {
            lock.unlock()
            return
        }
        discardsFinishedRecording = true
        currentState = .finalizing
        let output = recordingOutput ?? resolver.latest
        lock.unlock()
        PRMLog.notice(.capture, "Recording cancelled; discarding the file")
        output?.stopRecording()
    }

    /// AVFoundation's error as a ``PRMSessionError``, keeping an `AVError`'s code.
    static func sessionError(for error: any Error) -> PRMSessionError {
        if let avError = error as? AVError {
            return .captureFailed(avError)
        }
        return .videoRecordingFailed(error.localizedDescription)
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
        // A start cancelled by its task, or a recording `cancel()` is already discarding.
        let cancelled = continuation != nil && (isStartCancelled || discardsFinishedRecording)
        isStartCancelled = false
        if cancelled {
            // Stop it, drop the file when the finish arrives, and fail `start()` rather than
            // report a recording nobody will stop.
            discardsFinishedRecording = true
            currentState = .finalizing
        }
        lock.unlock()
        if cancelled {
            PRMLog.notice(.capture, "Recording started after start() was cancelled; stopping it")
            output.stopRecording()
            continuation?.resume(throwing: PRMSessionError.cancelled)
            return
        }
        continuation?.resume()
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        lock.lock()
        if let activeURL, activeURL.lastPathComponent != outputFileURL.lastPathComponent {
            lock.unlock()
            PRMLog.warning(.capture, "Ignoring a finish for a recording that isn't the active one", private: outputFileURL.path)
            return
        }
        let continuation = stopContinuation
        stopContinuation = nil
        // A finish that arrives while `start()` is still waiting means recording failed (or
        // was stopped) before it began; `didStartRecordingTo` will never come, so resume it
        // here or `start()` hangs.
        let pendingStart = startContinuation
        startContinuation = nil
        let startCancelled = isStartCancelled
        isStartCancelled = false
        let discards = discardsFinishedRecording
        discardsFinishedRecording = false
        let startedAt: Date? = if case let .recording(_, started) = currentState { started } else { finalizingStartedAt }
        finalizingStartedAt = nil
        activeURL = nil
        recordingOutput = nil
        currentState = .idle
        lock.unlock()

        let recordedSeconds = CMTimeGetSeconds(output.recordedDuration)
        let summary = "\(recordedSeconds.isFinite ? String(format: "%.1f", recordedSeconds) : "?") s, \(output.recordedFileSize) bytes"

        if discards, pendingStart == nil {
            PRMLog.notice(.capture, "Discarded the cancelled recording (\(summary))", private: outputFileURL.path, error: error)
            PRMTempFile.remove(outputFileURL)
            continuation?.resume(throwing: PRMSessionError.cancelled)
            return
        }

        if let pendingStart {
            if startCancelled || discards {
                PRMLog.notice(.capture, "Recording cancelled before it started")
                pendingStart.resume(throwing: PRMSessionError.cancelled)
            } else if let error {
                PRMLog.error(.capture, "Recording failed before it started", private: outputFileURL.path, error: error)
                pendingStart.resume(throwing: Self.sessionError(for: error))
            } else {
                PRMLog.error(.capture, "Recording finished before it started", private: outputFileURL.path)
                pendingStart.resume(throwing: PRMSessionError.videoRecordingFailed("Recording finished before it started"))
            }
            // The caller never sees this URL, so nothing else will clean it up.
            PRMTempFile.remove(outputFileURL)
            continuation?.resume(throwing: PRMSessionError.videoRecordingFailed("Recording never started"))
            return
        }

        // AVFoundation measures what it wrote; the wall clock is the fallback (tests, or a
        // file output that reports nothing).
        let duration = recordedSeconds.isFinite && recordedSeconds > 0
            ? recordedSeconds
            : startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if let error {
            // AVFoundation can report an error for a recording that still finished
            // (maximum duration or file size reached, for example): that file is usable.
            let finished = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            if finished {
                PRMLog.notice(.capture, "Recording finished with a limit reached (\(summary))", private: outputFileURL.path, error: error)
                continuation?.resume(returning: PRMRecording(url: outputFileURL, duration: duration))
                return
            }
            if continuation == nil {
                PRMLog.error(
                    .capture,
                    "Recording ended with an error while no stop() was pending (\(summary))",
                    private: outputFileURL.path,
                    error: error
                )
            } else {
                PRMLog.error(.capture, "Recording failed (\(summary))", private: outputFileURL.path, error: error)
            }
            continuation?.resume(throwing: Self.sessionError(for: error))
            return
        }
        if continuation == nil {
            // The session stopped underneath the recording.
            PRMLog.notice(.capture, "Recording finished while no stop() was pending (\(summary))", private: outputFileURL.path)
        } else {
            PRMLog.notice(.capture, "Recording finished: \(summary)", private: outputFileURL.path)
        }
        continuation?.resume(returning: PRMRecording(url: outputFileURL, duration: duration))
    }
}
