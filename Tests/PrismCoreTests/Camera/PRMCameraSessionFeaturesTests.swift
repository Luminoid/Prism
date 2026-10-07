import AVFoundation
import Testing
@testable import PrismCore

/// iOS 26 / 27 session features (`PRMCameraSession+Metadata`, `+Cinematic`, `+Features`).
/// The simulator has no camera, so these cover the pure helpers and the pre-configure
/// behavior: every feature must refuse cleanly rather than reach AVFoundation without an
/// input.
struct PRMCameraSessionFeaturesTests {
    // MARK: Metadata type resolution

    @Test
    func `Cinematic Video gets exactly its required types`() {
        let types = PRMCameraSession.effectiveMetadataObjectTypes(
            available: [.face, .humanBody, .catBody, .qr],
            cinematicRequired: [.face, .humanBody],
            cinematicEnabled: true,
            focusTrackedType: .salientObject,
            consumer: [.qr]
        )
        #expect(types == [.face, .humanBody])
    }

    @Test
    func `Cinematic types are not filtered by availability`() {
        // The SDK raises unless metadataObjectTypes equals the required list exactly once
        // the input has Cinematic Video on, even before every type reads as available.
        let types = PRMCameraSession.effectiveMetadataObjectTypes(
            available: [.face],
            cinematicRequired: [.face, .catBody],
            cinematicEnabled: true,
            focusTrackedType: nil,
            consumer: []
        )
        #expect(types == [.face, .catBody])
    }

    @Test
    func `Tracking type comes first, then consumer types, deduplicated`() {
        let types = PRMCameraSession.effectiveMetadataObjectTypes(
            available: [.salientObject, .face, .qr],
            cinematicRequired: [.face],
            cinematicEnabled: false,
            focusTrackedType: .salientObject,
            consumer: [.face, .salientObject, .face]
        )
        #expect(types == [.salientObject, .face])
    }

    @Test
    func `Unavailable types are dropped`() {
        let types = PRMCameraSession.effectiveMetadataObjectTypes(
            available: [.face],
            cinematicRequired: [],
            cinematicEnabled: false,
            focusTrackedType: nil,
            consumer: [.qr, .face, .ean13]
        )
        #expect(types == [.face])
    }

    // MARK: Pure helpers

    @Test
    func `Detection intervals compare including run-once`() {
        #expect(PRMCameraSession.sameDetectionInterval(.invalid, .invalid))
        #expect(!PRMCameraSession.sameDetectionInterval(.invalid, .zero))
        #expect(PRMCameraSession.sameDetectionInterval(CMTime(value: 60, timescale: 1), CMTime(value: 600, timescale: 10)))
        #expect(!PRMCameraSession.sameDetectionInterval(.zero, CMTime(value: 1, timescale: 1)))
    }

    @Test
    func `Cinematic zoom clamp ignores an empty range`() {
        #expect(PRMCameraSession.clampedZoom(5, min: 1, max: 3) == 3)
        #expect(PRMCameraSession.clampedZoom(0.5, min: 1, max: 3) == 1)
        #expect(PRMCameraSession.clampedZoom(2, min: 1, max: 3) == 2)
        #expect(PRMCameraSession.clampedZoom(5, min: 0, max: 0) == 5)
    }

    // MARK: Pre-configure behavior

    @Test
    @PRMCameraActor
    func `A fresh session has every feature off`() {
        let session = PRMCameraSession()
        #expect(session.metadataOutput == nil)
        #expect(!session.isCinematicVideoCaptureActive)
        #expect(!session.wantsCinematicVideo)
        #expect(!session.wantsContinuousAutoFocusTracking)
        #expect(session.cinematicSimulatedAperture == 0)
        #expect(!session.isCinematicVideoMetadataCaptureEnabled)
        #expect(!session.isLowLightVideoNoiseReductionActive)
        #expect(session.supportedFramings().isEmpty)
    }

    @Test
    @PRMCameraActor
    func `Cinematic Video refuses without an input`() async {
        let session = PRMCameraSession()
        await #expect(throws: PRMSessionError.self) {
            try await session.setCinematicVideoCaptureEnabled(true)
        }
        #expect(!session.wantsCinematicVideo)
        #expect(throws: PRMSessionError.self) {
            try session.setCinematicSimulatedAperture(2.8)
        }
    }

    @Test
    @PRMCameraActor
    func `Device access without a device returns nil`() {
        let session = PRMCameraSession()
        let result = session.withVideoDevice { _, cinematic in cinematic }
        #expect(result == nil)
    }

    @Test
    @PRMCameraActor
    func `Tracking refuses without a supporting device`() {
        let session = PRMCameraSession()
        #expect(throws: PRMSessionError.self) {
            try session.setContinuousAutoFocusTrackingEnabled(true)
        }
        #expect(!session.wantsContinuousAutoFocusTracking)
        #expect(throws: PRMSessionError.self) {
            try session.setContinuousAutoFocusTrackingBias(0.5)
        }
    }

    @Test
    @PRMCameraActor
    func `Dynamic aspect ratio refuses without a device`() async {
        let session = PRMCameraSession()
        await #expect(throws: PRMSessionError.self) {
            try await session.setDynamicAspectRatio(.ratio16x9)
        }
    }

    @Test
    @PRMCameraActor
    func `Health setters are safe before configure`() {
        let session = PRMCameraSession()
        session.setLensSmudgeDetection(interval: .zero)
        session.setLowLightVideoNoiseReduction(.on)
        session.setCinematicMetadataCapture(.enabled)
        session.setSmartFraming(enabledFramings: [PRMFraming(aspectRatio: .ratio1x1, zoomFactor: 1)])
        session.setSmartFraming(enabledFramings: nil)
        #expect(session.lensSmudgeDetectionInterval == .zero)
        #expect(session.lowLightVideoNoiseReduction == .on)
        #expect(session.cinematicMetadataCapture == .enabled)
        #expect(session.smartFramingIntent == nil)
    }

    @Test
    @PRMCameraActor
    func `Configuration resets feature intents`() {
        let session = PRMCameraSession()
        session.wantsContinuousAutoFocusTracking = true
        session.desiredDynamicAspectRatio = .ratio9x16
        session.resetFeatureIntents(from: PRMCameraConfiguration(
            lensSmudgeDetectionInterval: .invalid,
            metadataObjectTypes: [.face],
            enableCinematicVideo: true
        ))
        #expect(!session.wantsContinuousAutoFocusTracking)
        #expect(session.desiredDynamicAspectRatio == nil)
        #expect(session.wantsCinematicVideo)
        #expect(session.requestedMetadataObjectTypes == [.face])
        #expect(session.lensSmudgeDetectionInterval.map { !$0.isValid } == true)
    }
}
