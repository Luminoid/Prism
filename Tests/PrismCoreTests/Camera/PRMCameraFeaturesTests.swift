import AVFoundation
import Testing
@testable import PrismCore

/// iOS 26 / 27 facade APIs (`PRMCamera+ManualControls`, `+SessionHealth`, `+Tracking`,
/// `+Framing`). Without a camera every device call is a no-op, so these check the intent
/// bookkeeping, the error routing and the streams.
@MainActor
struct PRMCameraFeaturesTests {
    @Test
    func `No priority axes in the default auto state`() {
        let camera = PRMCamera()
        #expect(camera.exposurePriorityAxes.isEmpty)
    }

    @Test
    func `Shutter priority reports the shutter as locked while the device catches up`() async {
        let camera = PRMCamera()
        await camera.setShutterPriority(seconds: 1.0 / 250)
        #expect(camera.exposurePriorityAxes == [.shutter])
        #expect(camera.intendedExposureDurationSeconds == 1.0 / 250)
        #expect(camera.intendedISO == nil)
    }

    @Test
    func `Full manual is not a priority mode`() async {
        let camera = PRMCamera()
        await camera.setExposure(aperture: .current, shutterSeconds: .fixed(0.01), iso: .fixed(400))
        #expect(camera.exposurePriorityAxes.isEmpty)
        #expect(camera.currentManualExposureSnapshot?.iso == 400)
    }

    @Test
    func `Returning to auto clears the priority intents`() async {
        let camera = PRMCamera()
        await camera.setISOPriority(800)
        await camera.setExposureMode(.continuousAutoExposure)
        #expect(camera.intendedAutoExposureAxes == nil)
        #expect(camera.intendedLensAperture == nil)
        #expect(camera.exposurePriorityAxes.isEmpty)
    }

    @Test
    func `A tap-to-focus back to auto exposure drops priority intents`() async {
        let camera = PRMCamera()
        await camera.setShutterPriority(seconds: 1.0 / 125)
        await camera.setFocusAndExposure(focusMode: .autoFocus, exposureMode: .autoExpose, at: CGPoint(x: 0.5, y: 0.5))
        #expect(camera.intendedAutoExposureAxes == nil)
        #expect(camera.exposurePriorityAxes.isEmpty)
    }

    @Test
    func `Pinned intents follow the axis`() {
        #expect(PRMCamera.pinnedIntent(PRMExposureValue<Float>.fixed(2), current: 1) == 2)
        #expect(PRMCamera.pinnedIntent(PRMExposureValue<Float>.auto, current: 1) == nil)
        #expect(PRMCamera.pinnedIntent(PRMExposureValue<Float>.current, current: 1) == 1)
    }

    @Test
    func `Cinematic focus without Cinematic Video reports an error`() async {
        let camera = PRMCamera()
        var errors = camera.errorStream().makeAsyncIterator()
        await camera.setCinematicFocus(.trackPoint(CGPoint(x: 0.5, y: 0.5), mode: .strong))
        let error = await errors.next()
        guard case .unsupportedConfiguration = error else {
            Issue.record("Expected unsupportedConfiguration, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `Enabling Cinematic Video without a camera throws`() async {
        let camera = PRMCamera()
        await #expect(throws: PRMSessionError.self) {
            try await camera.setCinematicVideoEnabled(true)
        }
        #expect(!camera.state.isCinematicVideoCaptureEnabled)
    }

    @Test
    func `Cinematic aperture without Cinematic Video returns nil`() async {
        let camera = PRMCamera()
        let applied = await camera.setCinematicSimulatedAperture(4)
        #expect(applied == nil)
    }

    @Test
    func `Detected objects stream delivers what the router publishes`() async {
        let camera = PRMCamera()
        var iterator = camera.detectedObjectsStream().makeAsyncIterator()
        let tracked = PRMDetectedObject(kind: .focusTracked, bounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        camera.session.metadataRouter.publish([tracked])
        #expect(await iterator.next() == [tracked])
    }

    @Test
    func `Framing recommendations stream relays the session registry`() async {
        let camera = PRMCamera()
        var iterator = camera.framingRecommendationStream().makeAsyncIterator()
        let framing = PRMFraming(aspectRatio: .ratio16x9, zoomFactor: 1.2)
        camera.session.framingRecommendations.yield(framing)
        let next = await iterator.next()
        #expect(next == .some(framing))
    }

    @Test
    func `A late framing subscriber gets the current recommendation`() async {
        let camera = PRMCamera()
        let framing = PRMFraming(aspectRatio: .ratio9x16, zoomFactor: 1.5)
        camera.session.latestFramingRecommendation.withLock { $0 = framing }
        var iterator = camera.framingRecommendationStream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .some(framing))
    }

    @Test
    func `Aperture priority locks only the aperture`() async {
        let camera = PRMCamera()
        await camera.setAperturePriority(2.8)
        #expect(camera.exposurePriorityAxes == [.aperture])
        #expect(camera.intendedLensAperture == 2.8)
        #expect(camera.intendedISO == nil)
        #expect(camera.intendedExposureDurationSeconds == nil)
    }

    @Test
    func `An auto-exposure tap drops pinned manual values`() async {
        let camera = PRMCamera()
        await camera.setCustomExposure(duration: CMTimeMakeWithSeconds(0.01, preferredTimescale: 1_000_000), iso: 400)
        #expect(camera.intendedISO == 400)
        await camera.setFocusAndExposure(focusMode: .autoFocus, exposureMode: .continuousAutoExposure, at: CGPoint(x: 0.5, y: 0.5))
        #expect(camera.intendedISO == nil)
        #expect(camera.intendedExposureDurationSeconds == nil)
        await camera.setShutterPriority(seconds: 1.0 / 60)
        await camera.setFocusAndExposure(focusMode: .autoFocus, exposureMode: .autoExpose, in: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(camera.intendedAutoExposureAxes == nil)
        #expect(camera.intendedExposureDurationSeconds == nil)
    }

    @Test
    func `A lens move without a camera returns instead of waiting forever`() async {
        let camera = PRMCamera()
        // Before the fix this awaited a stream nothing would ever finish.
        await camera.setLensPosition(0.5)
        #expect(camera.state.lensPosition == PRMCameraState().lensPosition)
    }

    @Test
    func `Facade signatures compile`() {
        let rateLimit: (PRMCamera) -> (Float) async -> Void = { camera in camera.setAutoApertureRateLimit }
        let cinematicFocus: (PRMCamera) -> (PRMCinematicFocusRequest) async -> Void = { camera in camera.setCinematicFocus }
        let metadataCapture: (PRMCamera) -> (PRMCinematicMetadataCapture) async -> Void = { camera in camera.setCinematicMetadataCapture }
        let metadataTypes: (PRMCamera) -> ([AVMetadataObject.ObjectType]) async -> Void = { camera in camera.setMetadataObjectTypes }
        let framings: (PRMCamera) -> () async -> [PRMFraming] = { camera in camera.supportedFramings }
        let smartFraming: (PRMCamera) -> ([PRMFraming]?) async -> Void = { camera in camera.setSmartFraming }
        let focusRect: (PRMCamera) -> (CGPoint) async -> CGRect? = { camera in camera.defaultFocusRect }
        _ = (rateLimit, cinematicFocus, metadataCapture, metadataTypes, framings, smartFraming, focusRect)
        let setExposure: (PRMCamera) -> (PRMExposureValue<Float>, PRMExposureValue<Double>, PRMExposureValue<Float>) async -> Void =
            { camera in camera.setExposure }
        let lockLens: (PRMCamera) -> (AVCaptureDevice.DeviceType?) async -> Void = { camera in camera.lockLens }
        let signals: (PRMCamera) -> (Set<PRMExposureSignal>?) async -> Void = { camera in camera.setExposureSignals }
        let smudge: (PRMCamera) -> (CMTime?) async -> Void = { camera in camera.setLensSmudgeDetection }
        let noise: (PRMCamera) -> (PRMLowLightVideoNoiseReduction) async -> Void = { camera in camera.setLowLightVideoNoiseReduction }
        let tracking: (PRMCamera) -> (Bool) async -> Void = { camera in camera.setContinuousAutoFocusTrackingEnabled }
        let cinematic: (PRMCamera) -> (Bool, Bool?) async throws -> Void = { camera in camera.setCinematicVideoEnabled }
        let aspect: (PRMCamera) -> (PRMAspectRatio) async throws -> Void = { camera in camera.setDynamicAspectRatio }
        let framing: (PRMCamera) -> (PRMFraming) async throws -> Void = { camera in camera.applyFraming }
        let focusMode: (PRMCamera) -> (AVCaptureDevice.FocusMode) async -> Void = { camera in camera.setFocusMode }
        _ = (setExposure, lockLens, signals, smudge, noise, tracking, cinematic, aspect, framing, focusMode)
    }
}
