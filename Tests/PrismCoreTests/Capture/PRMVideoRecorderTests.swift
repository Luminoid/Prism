import AVFoundation
import Foundation
import Testing
@testable import PrismCore

/// `PRMVideoRecorder` wraps `AVCaptureMovieFileOutput`. Like `PRMPhotoCapture`, the full
/// `start()`/`stop()` flow requires an attached, running `AVCaptureSession` with a video
/// input — out of scope for unit tests. We cover:
///
/// - Initialization and output retention.
/// - Initial state is `.idle`.
/// - `stop()` rejects when not recording.
/// - A finish that arrives before the start resumes the pending start (driven through
///   `waitForRecordingStart`, since `start()` needs a live connection).
/// - `State` equality semantics.
/// - Sendable across actor hops.
struct PRMVideoRecorderTests {
    @Test
    func `Initializer retains the output and starts idle`() {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        #expect(recorder.output === output)
        #expect(recorder.state == .idle)
    }

    @Test
    func `stop() throws when not recording`() async {
        let recorder = PRMVideoRecorder(output: AVCaptureMovieFileOutput())
        do {
            _ = try await recorder.stop()
            Issue.record("Expected stop() to throw when state is .idle")
        } catch let error as PRMSessionError {
            // Specifically: videoRecordingFailed with a "Not currently recording" message.
            if case let .videoRecordingFailed(reason) = error {
                #expect(reason.contains("Not currently recording"))
            } else {
                Issue.record("Unexpected PRMSessionError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error)) — \(error)")
        }
        // State stays idle after a failed stop.
        #expect(recorder.state == .idle)
    }

    @Test
    func `State Equatable cases`() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        let date = Date(timeIntervalSince1970: 0)
        #expect(PRMVideoRecorder.State.idle == PRMVideoRecorder.State.idle)
        #expect(PRMVideoRecorder.State.recording(url: url, startedAt: date) ==
            PRMVideoRecorder.State.recording(url: url, startedAt: date))
        #expect(PRMVideoRecorder.State.finalizing == PRMVideoRecorder.State.finalizing)
        #expect(PRMVideoRecorder.State.idle != PRMVideoRecorder.State.finalizing)
    }

    @Test
    func `Conforms to AVCaptureFileOutputRecordingDelegate`() {
        // Compile-time conformance check — protects the delegate hookup.
        let recorder = PRMVideoRecorder(output: AVCaptureMovieFileOutput())
        let asDelegate: any AVCaptureFileOutputRecordingDelegate = recorder
        _ = asDelegate
    }

    // MARK: - Finish before start

    // `start()` itself needs a live video connection, so these drive the continuation
    // directly: `waitForRecordingStart` installs it the same way `start()` does, and the
    // delegate callback arrives before `didStartRecordingTo` ever could.

    @Test
    func `A failed finish before the start makes start throw instead of hanging`() async {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
        do {
            try await recorder.waitForRecordingStart(url: url) {
                recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: failure)
            }
            Issue.record("Expected the start to fail")
        } catch let error as PRMSessionError {
            // AVFoundation's error keeps its code.
            guard case let .captureFailed(avError) = error, avError.code == .diskFull else {
                Issue.record("Unexpected PRMSessionError case: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
        #expect(recorder.state == .idle)
    }

    @Test
    func `A clean finish before the start also makes start throw`() async {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        do {
            try await recorder.waitForRecordingStart(url: url) {
                recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
            }
            Issue.record("Expected the start to fail")
        } catch let error as PRMSessionError {
            if case let .videoRecordingFailed(reason) = error {
                #expect(reason.contains("before it started"))
            } else {
                Issue.record("Unexpected PRMSessionError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
        #expect(recorder.state == .idle)
    }

    @Test
    func `A start that arrives after cancellation throws cancelled and stops the recording`() async {
        // Only read inside the task below, never concurrently.
        nonisolated(unsafe) let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        // Cancelled before the continuation exists, so `onCancel` has nothing to flag.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await recorder.waitForRecordingStart(url: url) {
                recorder.fileOutput(output, didStartRecordingTo: url, from: [])
            }
        }
        if case let .failure(error) = await task.result {
            #expect(error as? PRMSessionError == .cancelled)
        } else {
            Issue.record("Expected start to throw .cancelled")
        }
        #expect(recorder.state == .finalizing)
        // The stopped recording's finish is discarded and settles the recorder.
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
        #expect(recorder.state == .idle)
    }

    @Test
    func `A finish before the start of a cancelled task throws cancelled`() async {
        // Only read inside the task below, never concurrently.
        nonisolated(unsafe) let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await recorder.waitForRecordingStart(url: url) {
                recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
            }
        }
        if case let .failure(error) = await task.result {
            #expect(error as? PRMSessionError == .cancelled)
        } else {
            Issue.record("Expected start to throw .cancelled")
        }
        #expect(recorder.state == .idle)
    }

    @Test
    func `A start reported by the delegate resumes start normally`() async throws {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        try await recorder.waitForRecordingStart(url: url) {
            recorder.fileOutput(output, didStartRecordingTo: url, from: [])
        }
        guard case let .recording(recordingURL, _) = recorder.state else {
            Issue.record("Expected .recording, got \(recorder.state)")
            return
        }
        #expect(recordingURL == url)
    }

    @Test
    func `A stopped recording reports the time since its start as its duration`() async throws {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        try await recorder.waitForRecordingStart(url: url) {
            recorder.fileOutput(output, didStartRecordingTo: url, from: [])
        }
        try await Task.sleep(for: .milliseconds(20))
        async let stopped = recorder.stop()
        // `stop()` moves to `.finalizing` before AVFoundation reports the finish.
        for _ in 0 ..< 1000 where recorder.state != .finalizing {
            await Task.yield()
        }
        #expect(recorder.state == .finalizing)
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
        let recording = try await stopped
        #expect(recording.duration >= 0.02)
        #expect(recorder.state == .idle)
    }

    // MARK: - Finalizing, stop and cancel

    /// Puts the recorder in `.recording` through the delegate, as `start()` would.
    private func startedRecorder() async throws -> (PRMVideoRecorder, AVCaptureMovieFileOutput, URL) {
        let output = AVCaptureMovieFileOutput()
        let recorder = PRMVideoRecorder(output: output)
        let url = PRMTempFile.url(withExtension: "mov")
        try await recorder.waitForRecordingStart(url: url) {
            recorder.fileOutput(output, didStartRecordingTo: url, from: [])
        }
        return (recorder, output, url)
    }

    @Test
    func `Starting while the previous recording finalizes throws instead of deleting it`() async throws {
        let (recorder, output, url) = try await startedRecorder()
        async let stopped = recorder.stop()
        for _ in 0 ..< 1000 where recorder.state != .finalizing {
            await Task.yield()
        }
        do {
            try await recorder.start()
            Issue.record("Expected start() to refuse while finalizing")
        } catch let error as PRMSessionError {
            guard case let .videoRecordingFailed(reason) = error else {
                Issue.record("Unexpected PRMSessionError case: \(error)")
                return
            }
            #expect(reason.contains("finalizing"))
        }
        // The first recording still finishes normally.
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
        let recording = try await stopped
        #expect(recording.url == url)
        #expect(recorder.state == .idle)
    }

    @Test
    func `A second stop while finalizing throws and the first still returns`() async throws {
        let (recorder, output, url) = try await startedRecorder()
        async let first = recorder.stop()
        for _ in 0 ..< 1000 where recorder.state != .finalizing {
            await Task.yield()
        }
        await #expect(throws: PRMSessionError.self) {
            _ = try await recorder.stop()
        }
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
        #expect(try await first.url == url)
    }

    @Test
    func `Cancel discards the file once the finish arrives`() async throws {
        let (recorder, output, url) = try await startedRecorder()
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        recorder.cancel()
        #expect(recorder.state == .finalizing)
        // Still there until AVFoundation reports the finish.
        #expect(FileManager.default.fileExists(atPath: url.path))
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(recorder.state == .idle)
    }

    @Test
    func `A finish for another file leaves the recording alone`() async throws {
        let (recorder, output, url) = try await startedRecorder()
        let stale = PRMTempFile.url(withExtension: "mov")
        recorder.fileOutput(output, didFinishRecordingTo: stale, from: [], error: nil)
        guard case let .recording(recordingURL, _) = recorder.state else {
            Issue.record("Expected .recording, got \(recorder.state)")
            return
        }
        #expect(recordingURL == url)
    }

    @Test
    func `A recording that hit a limit is returned, not thrown`() async throws {
        let (recorder, output, url) = try await startedRecorder()
        async let stopped = recorder.stop()
        for _ in 0 ..< 1000 where recorder.state != .finalizing {
            await Task.yield()
        }
        let limit = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.maximumDurationReached.rawValue,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true]
        )
        recorder.fileOutput(output, didFinishRecordingTo: url, from: [], error: limit)
        #expect(try await stopped.url == url)
    }

    @Test
    func `Sendable across actor hops`() async {
        let recorder = PRMVideoRecorder(output: AVCaptureMovieFileOutput())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = recorder.state
                continuation.resume()
            }
        }
    }
}
