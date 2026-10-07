import AVFoundation
import Testing
@testable import PrismCore

/// `PRMCameraSession+Controls.swift`, `+State.swift` and the lifecycle flags on a session with
/// no device (the simulator has no camera): every control must be a quiet no-op, never a
/// raise or a hang.
@PRMCameraActor
struct PRMCameraSessionControlsTests {
    @Test
    func `Controls without a device do nothing`() throws {
        let session = PRMCameraSession()
        try session.setZoom(2)
        try session.rampZoom(to: 2, rate: 1)
        #expect(try session.setFrameRate(240) == nil)
        try session.resetFrameRate()
        #expect(try session.enableDepthFormat() == false)
        #expect(session.stateSnapshot() == nil)
    }

    @Test
    func `Nothing is recording on a fresh session`() throws {
        let session = PRMCameraSession()
        try session.refuseWhileBusy("Test")
        try session.setMovieFileOutputAttached(false)
    }

    @Test
    func `A Night capture refuses reconfigurations and zoom until it ends`() throws {
        let session = PRMCameraSession()
        #expect(!session.isExclusiveCaptureActive)
        session.exclusiveCaptureOwner = "a Night capture"
        #expect(session.isExclusiveCaptureActive)
        #expect(throws: PRMSessionError.self) { try session.refuseWhileBusy("Switching cameras") }
        #expect(throws: PRMSessionError.self) { try session.refuseDuringExclusiveCapture("Zooming") }
        session.exclusiveCaptureOwner = nil
        try session.refuseWhileBusy("Switching cameras")
    }

    @Test
    func `The running flag reads the capture session`() {
        let session = PRMCameraSession()
        #expect(!session.isRunning)
        #expect(!session.wantsRunning)
        // Not wanted, so no restart.
        session.restartAfterMediaServicesReset()
        #expect(!session.isRunning)
    }

    @Test
    func `Stabilization and 48MP choices are kept as intents`() throws {
        let session = PRMCameraSession()
        session.setStabilization(.cinematic)
        #expect(session.stabilizationMode == .cinematic)
        try session.setHighResolutionPhotoFormat(true)
        #expect(session.wantsHighResolutionPhotoFormat)
        try session.setHighResolutionPhotoFormat(false)
        #expect(!session.wantsHighResolutionPhotoFormat)
    }

    @Test
    func `The preview never gets a latency-heavy stabilization mode`() {
        // Photo modes (no movie output) and stabilization off: unstabilized.
        for requested: AVCaptureVideoStabilizationMode in [.auto, .cinematic, .cinematicExtended, .standard, .off] {
            #expect(PRMCameraSession.previewStabilizationMode(requested: requested, hasMovieOutput: false, supportsLowLatency: true) == .off)
        }
        #expect(PRMCameraSession.previewStabilizationMode(requested: .off, hasMovieOutput: true, supportsLowLatency: true) == .off)
        // A format without the low-latency mode falls back to unstabilized, never to the request.
        #expect(PRMCameraSession.previewStabilizationMode(requested: .cinematic, hasMovieOutput: true, supportsLowLatency: false) == .off)
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Video modes preview with low-latency stabilization`() {
        guard #available(iOS 26.0, *) else { return }
        for requested: AVCaptureVideoStabilizationMode in [.auto, .cinematic, .cinematicExtended, .standard] {
            #expect(PRMCameraSession.previewStabilizationMode(requested: requested, hasMovieOutput: true, supportsLowLatency: true) == .lowLatency)
        }
    }

    @Test
    func `Detaching a depth stream that was never attached is a no-op`() async {
        let session = PRMCameraSession()
        await session.detachDepthDataOutput()
        #expect(session.depthDataOutput == nil)
    }
}
