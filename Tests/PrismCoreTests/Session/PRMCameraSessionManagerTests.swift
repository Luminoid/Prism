import AVFoundation
import Synchronization
import Testing
@testable import PrismCore

// MARK: - MockCameraDelegate

final class MockCameraDelegate: PRMCameraDelegate, @unchecked Sendable {
    var focusCallCount = 0
    var lastFocusPoint: CGPoint?

    func didUpdateFocusAndExposure(
        at point: CGPoint,
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
    ) {
        focusCallCount += 1
        lastFocusPoint = point
    }
}

// MARK: - PRMCameraSessionManagerTests

@Suite("PRMCameraSessionManager")
struct PRMCameraSessionManagerTests {
    // MARK: - Initialization

    @Test("Initial setup result is success")
    func initialSetupResult() {
        let manager = PRMCameraSessionManager()
        #expect(manager.setupResult == .success)
    }

    @Test("Session is not running initially")
    func notRunningInitially() {
        let manager = PRMCameraSessionManager()
        #expect(!manager.isSessionRunning)
    }

    @Test("No video device initially")
    func noVideoDeviceInitially() {
        let manager = PRMCameraSessionManager()
        #expect(manager.videoDevice == nil)
    }

    @Test("No video device input initially")
    func noVideoDeviceInputInitially() {
        let manager = PRMCameraSessionManager()
        #expect(manager.videoDeviceInput == nil)
    }

    @Test("No photo output initially")
    func noPhotoOutputInitially() {
        let manager = PRMCameraSessionManager()
        #expect(manager.photoOutput == nil)
    }

    @Test("No video data output initially")
    func noVideoDataOutputInitially() {
        let manager = PRMCameraSessionManager()
        #expect(manager.videoDataOutput == nil)
    }

    // MARK: - Session Queue

    @Test("Session queue is accessible")
    func sessionQueueAccessible() {
        let manager = PRMCameraSessionManager()
        // Verify we can dispatch to it without deadlock
        let expectation = Mutex(false)
        manager.sessionQueue.async {
            expectation.withLock { $0 = true }
        }
        // Wait briefly for the queue to execute
        Thread.sleep(forTimeInterval: 0.1)
        #expect(expectation.withLock { $0 })
    }

    // MARK: - Delegate

    @Test("Camera delegate can be set")
    func delegateSetup() {
        let manager = PRMCameraSessionManager()
        let delegate = MockCameraDelegate()
        manager.cameraDelegate = delegate
        #expect(manager.cameraDelegate != nil)
    }

    // MARK: - Callbacks

    @Test("Callback closures can be set")
    func callbackSetup() {
        let manager = PRMCameraSessionManager()
        manager.onSessionRunningChanged = { _ in }
        manager.onSessionInterrupted = { _ in }
        manager.onSessionInterruptionEnded = {}
        manager.onSessionRuntimeError = { _ in }
    }

    // MARK: - Switch Camera

    @Test("Switch camera returns false with no input")
    func switchWithNoInput() {
        let manager = PRMCameraSessionManager()
        let result = manager.switchCamera(to: .front)
        #expect(!result)
    }
}
