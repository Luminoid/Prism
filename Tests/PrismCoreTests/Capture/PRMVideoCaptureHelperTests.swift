import AVFoundation
import Testing
@testable import PrismCore

// MARK: - PRMVideoCaptureHelperTests

@Suite("PRMVideoCaptureHelper")
struct PRMVideoCaptureHelperTests {
    // MARK: - Initialization

    @Test("Initial state is idle")
    func initialState() {
        let helper = PRMVideoCaptureHelper()
        #expect(helper.state == .idle)
    }

    @Test("Output URL is nil initially")
    func initialOutputURL() {
        let helper = PRMVideoCaptureHelper()
        #expect(helper.outputURL == nil)
    }

    // MARK: - State Enum

    @Test("All recording states exist")
    func allStates() {
        let idle: PRMVideoRecordingState = .idle
        let recording: PRMVideoRecordingState = .recording
        let finalizing: PRMVideoRecordingState = .finalizing
        #expect(idle != recording)
        #expect(recording != finalizing)
        #expect(idle != finalizing)
    }

    @Test("Recording state is equatable")
    func stateEquatable() {
        #expect(PRMVideoRecordingState.idle == .idle)
        #expect(PRMVideoRecordingState.recording == .recording)
        #expect(PRMVideoRecordingState.finalizing == .finalizing)
    }

    // MARK: - Callbacks

    @Test("Recording started callback can be set")
    func recordingStartedCallback() {
        let helper = PRMVideoCaptureHelper()
        var called = false
        helper.onRecordingStarted = { called = true }
        helper.onRecordingStarted?()
        #expect(called)
    }

    @Test("Recording finished callback can be set")
    func recordingFinishedCallback() {
        let helper = PRMVideoCaptureHelper()
        var receivedURL: URL?
        helper.onRecordingFinished = { url, _ in receivedURL = url }
        let testURL = URL(fileURLWithPath: "/tmp/test.mov")
        helper.onRecordingFinished?(testURL, nil)
        #expect(receivedURL == testURL)
    }

    // MARK: - Stop Without Start

    @Test("Stop recording does nothing when idle")
    func stopWhenIdle() {
        let helper = PRMVideoCaptureHelper()
        let output = AVCaptureMovieFileOutput()
        helper.stopRecording(to: output)
        #expect(helper.state == .idle)
    }
}
