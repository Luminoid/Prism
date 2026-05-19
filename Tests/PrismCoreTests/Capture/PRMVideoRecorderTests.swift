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
/// - `stop()` rejects when not recording (the only error path reachable without a session).
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
