import AVFoundation
import ImageIO
import Testing
@testable import PrismCore

/// `PRMNightModeCapture` needs a camera for the capture itself; here: the API surface, the
/// refusals without one, frame acceptance by exposure metadata, and the photo's metadata.
struct PRMNightModeCaptureTests {
    @Test
    func `Public API surface compiles`() {
        let sessionKP: KeyPath<PRMNightModeCapture, PRMCameraSession> = \.session
        let plan: (PRMNightModeCapture) -> (PRMNightModeOptions) async -> PRMNightPlan? = { $0.plan }
        let capture: (PRMNightModeCapture) -> (PRMNightModeOptions, (@Sendable (PRMNightProgress) -> Void)?) async throws -> PRMNightPhoto = { $0.capture }
        _ = (sessionKP, plan, capture)
        let options = PRMNightModeOptions()
        #expect(options.duration == .automatic)
        #expect(!options.isStable)
    }

    @Test
    func `Without a camera there's no plan and the capture is refused`() async throws {
        let session = PRMCameraSession()
        let night = try PRMNightModeCapture(session: session, context: #require(PRMRenderContext()))
        #expect(await night.plan() == nil)
        do {
            _ = try await night.capture()
            Issue.record("Expected the capture to throw")
        } catch let error as PRMSessionError {
            guard case .unsupportedConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        // Refused before taking the camera: nothing left held.
        #expect(await session.isExclusiveCaptureActive == false)
    }

    @Test
    func `The countdown rounds up and stops while processing`() {
        let capturing = PRMNightProgress(phase: .capturing, elapsed: 0.2, duration: 3, mergedFrames: 1, plannedFrames: 24)
        #expect(capturing.secondsRemaining == 3)
        let late = PRMNightProgress(phase: .capturing, elapsed: 2.95, duration: 3, mergedFrames: 23, plannedFrames: 24)
        #expect(late.secondsRemaining == 1)
        let processing = PRMNightProgress(phase: .processing, elapsed: 3, duration: 3, mergedFrames: 24, plannedFrames: 24)
        #expect(processing.secondsRemaining == 0)
    }

    @Test
    func `Frames count only at the planned exposure`() {
        let plan = PRMNightPlan(duration: 3, frameDuration: 0.125, iso: 2000, frameCount: 24)
        func exif(_ shutter: Double, _ iso: Int?) -> [String: Any] {
            var dictionary: [String: Any] = [kCGImagePropertyExifExposureTime as String: shutter]
            if let iso {
                dictionary[kCGImagePropertyExifISOSpeedRatings as String] = [NSNumber(value: iso)]
            }
            return [kCGImagePropertyExifDictionary as String: dictionary]
        }
        #expect(PRMNightStacker.exposureMatches(exif(0.125, 2000), plan: plan) == true)
        #expect(PRMNightStacker.exposureMatches(exif(0.13, 2200), plan: plan) == true)
        // Still at the old exposure.
        #expect(PRMNightStacker.exposureMatches(exif(1.0 / 30, 2000), plan: plan) == false)
        #expect(PRMNightStacker.exposureMatches(exif(0.125, 800), plan: plan) == false)
        // No ISO: the shutter decides.
        #expect(PRMNightStacker.exposureMatches(exif(0.125, nil), plan: plan) == true)
        // No metadata at all: unknown.
        #expect(PRMNightStacker.exposureMatches(nil, plan: plan) == nil)
        #expect(PRMNightStacker.exposureMatches([:], plan: plan) == nil)
    }

    @Test
    func `One sharp frame doesn't make the rest look blurred`() {
        // The 2026-10-08 device run: the first frame measured 10, every later one 4 to 5.
        var gate = PRMNightStacker.SharpnessGate()
        let admitted: [Bool] = [10, 5, 5, 4.6, 4, 4.4, 5, 4].map { gate.admits(Float($0)) }
        #expect(!admitted.contains(false))
    }

    @Test
    func `A shaken frame in a sharp burst is rejected`() {
        var gate = PRMNightStacker.SharpnessGate()
        let admitted: [Bool] = [100, 95, 105, 30, 98].map { gate.admits(Float($0)) }
        #expect(admitted == [true, true, true, false, true])
        #expect(gate.typical == 98)
    }

    @Test
    func `Frames that arrive mid-merge count as skipped, not rejected`() {
        #expect(PRMNightStacker.intake(isAccepting: true, isBusy: false, merged: 3, planned: 30, atPlannedExposure: true) == .merge)
        #expect(PRMNightStacker.intake(isAccepting: true, isBusy: true, merged: 3, planned: 30, atPlannedExposure: true) == .skip)
        // Not wanted at all: before the exposure lands, once the plan is full, after the capture.
        #expect(PRMNightStacker.intake(isAccepting: true, isBusy: true, merged: 3, planned: 30, atPlannedExposure: false) == .ignore)
        #expect(PRMNightStacker.intake(isAccepting: true, isBusy: false, merged: 30, planned: 30, atPlannedExposure: true) == .ignore)
        #expect(PRMNightStacker.intake(isAccepting: false, isBusy: false, merged: 3, planned: 30, atPlannedExposure: true) == .ignore)
    }

    @Test
    func `The photo's metadata keeps the camera's and records the stack`() throws {
        let plan = PRMNightPlan(duration: 3, frameDuration: 0.125, iso: 2016.4, frameCount: 24)
        let attachments: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.78,
                kCGImagePropertyExifExposureTime as String: 1.0 / 30,
                kCGImagePropertyExifPixelXDimension as String: 4032,
            ],
        ]
        let metadata = PRMNightModeCapture.metadata(attachments: attachments, plan: plan, mergedFrames: 21, date: Date(timeIntervalSince1970: 0))
        let exif = try #require(metadata[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifFNumber as String] as? Double == 1.78)
        #expect(exif[kCGImagePropertyExifExposureTime as String] as? Double == 0.125)
        #expect((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue == 2016)
        #expect((exif[kCGImagePropertyExifUserComment as String] as? String)?.contains("21 frames") == true)
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] == nil)
        let tiff = try #require(metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
    }

    @Test
    func `Memory is checked only where it's tracked`() {
        // The simulator reports 0 available: the check passes.
        #expect(PRMNightModeCapture.hasMemory(forWidth: 4032, height: 3024))
    }
}

/// `PRMVideoFrameRouter`: observers get each frame; the app's delegate is kept.
struct PRMVideoFrameRouterTests {
    @Test
    func `Observers receive frames until removed`() throws {
        let router = PRMVideoFrameRouter()
        let pixelBuffer = try #require(NightTestImages.bgraBuffer(width: 8, height: 8) { _, _ in (0, 0, 0) })
        let sample = try #require(NightTestImages.sampleBuffer(pixelBuffer))
        let counter = Counter()
        let id = router.addObserver { _ in counter.increment() }
        #expect(router.observerCount == 1)
        router.notifyObservers(sample)
        router.notifyObservers(sample)
        #expect(counter.value == 2)
        router.removeObserver(id)
        #expect(router.observerCount == 0)
        router.notifyObservers(sample)
        #expect(counter.value == 2)
    }

    @Test
    func `Setting the session's delegate keeps it in the router`() async {
        let session = PRMCameraSession()
        let pipeline = PRMFilterPipeline()
        await session.setVideoDataOutputDelegate(pipeline)
        // No output yet (no camera on the simulator); nothing to deliver, nothing to raise.
        #expect(session.frameRouter.observerCount == 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }
}
