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

    /// Resolution strategy for the underlying `AVCaptureMovieFileOutput`.
    private enum OutputResolver: @unchecked Sendable {
        /// Fixed output instance. Used by the legacy `init(output:)`.
        case fixed(AVCaptureMovieFileOutput)
        /// Dynamic lookup against a session. Used by `init(session:)` — re-resolves
        /// at every `start()` so format-swap-driven output re-attaches don't strand
        /// the recorder against a dead output instance.
        case dynamic(@Sendable () async -> AVCaptureMovieFileOutput?)
    }

    private let resolver: OutputResolver
    public private(set) var state: State = .idle

    /// The output the recorder was constructed against (legacy init) or — for the
    /// session-based init — the output snapshotted at construction time. The
    /// session-based init resolves the LIVE output at `start()` time; this property
    /// is a stable reference for back-compat only and may be stale after a format
    /// swap. Prefer the session-based init.
    public var output: AVCaptureMovieFileOutput {
        if case let .fixed(out) = resolver {
            return out
        }
        // Resolved lazily for the session-based init via `currentOutput()`; the
        // property is provided for back-compat with code that read `.output` once
        // at construction time. Production callers should rely on `start()` to
        // resolve a fresh reference.
        if let cached = sessionCachedOutput {
            return cached
        }
        // Safe fallback: a fresh empty output. Should never be used in practice
        // because session-based callers go through `start()` which calls the
        // dynamic resolver. This branch only fires if a caller reads `.output`
        // before any `start()` has resolved one.
        return AVCaptureMovieFileOutput()
    }

    /// Cached output from the most recent `start()` resolution (session-based init
    /// only). Updated under `lock`.
    private var sessionCachedOutput: AVCaptureMovieFileOutput?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<PRMRecording, Error>?

    private let lock = NSLock()

    // MARK: - Init

    /// Legacy init. The recorder is bound to `output` permanently — if AVFoundation
    /// later replaces that output (e.g. on a format-swap-driven re-attach during
    /// slo-mo activation), `start()` will fail with a typed error. Prefer
    /// ``init(session:)`` for any session that may swap formats.
    public init(output: AVCaptureMovieFileOutput) {
        resolver = .fixed(output)
        super.init()
    }

    /// Session-based init. The recorder resolves `session.movieFileOutput` at every
    /// `start()` call, so format-swap-driven output replacements (e.g. Prism's
    /// internal re-attach when transitioning to a 240 fps slo-mo format) are
    /// invisible to the caller — the next `start()` automatically picks up the
    /// fresh output instance.
    ///
    /// `start()` throws ``PRMSessionError/videoRecordingFailed`` if the session
    /// has no movie output attached at start time (i.e. the consuming app forgot
    /// to call `setMovieFileOutputAttached(true)` for video mode).
    public init(session: PRMCameraSession) {
        // `nonisolated(unsafe)` is safe here — the closure only reads the actor-
        // isolated `movieFileOutput` snapshot through `await`, never mutates it.
        // The `@PRMCameraActor` isolation on the read ensures consistency with
        // any concurrent session reconfigure.
        resolver = .dynamic { [weak session] in
            guard let session else { return nil }
            return await session.movieFileOutput
        }
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

        // Resolve the LIVE output at start time. For session-based recorders this
        // re-reads `session.movieFileOutput` — necessary because Prism may have
        // detached + re-attached the movie output during a format-swap-driven
        // `setFrameRate` (slo-mo activation). For legacy `init(output:)`
        // recorders, the resolver returns the fixed reference.
        let resolvedOutput = await currentOutput()
        guard let resolvedOutput else {
            throw PRMSessionError.videoRecordingFailed(
                "AVCaptureMovieFileOutput is not attached to the session — call setMovieFileOutputAttached(true) before recording"
            )
        }

        // Cache the resolved output for legacy callers reading `.output` after a
        // session-based session reconfigure (back-compat surface). Use the
        // dedicated helper instead of inline `lock.lock()` because direct
        // `NSLock.lock` is unavailable from async contexts; the helper does the
        // same work inside a non-async scope where `NSLock` is the right tool
        // (the critical section is too short to justify an actor).
        cacheResolvedOutput(resolvedOutput)

        let url = PRMTempFile.url(withExtension: "mov")
        // Validate the video connection exists AND is enabled BEFORE calling
        // `startRecording`. AVFoundation's underlying ObjC implementation throws
        // `NSInvalidArgumentException` ("*** -[AVCaptureMovieFileOutput
        // startRecordingToOutputFileURL:recordingDelegate:] No active/enabled
        // connections") when it doesn't, and an uncaught ObjC exception in a Swift
        // async context terminates the process — there's no try/catch we can wrap
        // around it. Surface a typed Swift error instead so the consuming app can
        // show a "video pipeline not ready" toast and reconfigure.
        //
        // This guards against the class of bug where some other code path detached
        // the movie output (mode-switch race, full session reconfigure that didn't
        // preserve runtime mutations, etc.) between the consuming app deciding it's
        // in video mode and the user tapping record.
        guard let connection = resolvedOutput.connection(with: .video) else {
            throw PRMSessionError.videoRecordingFailed(
                "AVCaptureMovieFileOutput has no video connection — was the movie output attached to the session?"
            )
        }
        guard connection.isEnabled, connection.isActive else {
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

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                startContinuation = continuation
                state = .recording(url: url, startedAt: Date())
                lock.unlock()
                resolvedOutput.startRecording(to: url, recordingDelegate: self)
            }
        } onCancel: { [weak self] in
            // Stop on whatever output is current — for session-based recorders
            // the consuming app may have hopped the output again between start
            // and cancel; resolve fresh so we don't ask a dead output to stop.
            Task { await self?.currentOutput()?.stopRecording() }
        }
    }

    /// Returns the live `AVCaptureMovieFileOutput` per the configured resolver.
    /// Synchronous for `init(output:)`, actor-isolated read for `init(session:)`.
    private func currentOutput() async -> AVCaptureMovieFileOutput? {
        switch resolver {
        case let .fixed(out):
            out
        case let .dynamic(resolve):
            await resolve()
        }
    }

    /// Non-async cache update under the recorder's lock. Extracted from `start()`
    /// because `NSLock.lock` is not available in async contexts; calling it from
    /// a `nonisolated` helper sidesteps that restriction (the critical section is
    /// O(1) memory stores, too small to justify an actor).
    private nonisolated func cacheResolvedOutput(_ output: AVCaptureMovieFileOutput) {
        lock.lock()
        defer { lock.unlock() }
        sessionCachedOutput = output
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
