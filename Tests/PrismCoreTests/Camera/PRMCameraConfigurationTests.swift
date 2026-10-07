import AVFoundation
import Testing
@testable import PrismCore

struct PRMCameraConfigurationTests {
    @Test
    func `Defaults match photo + filter preset`() {
        let config = PRMCameraConfiguration()
        #expect(config.sessionPreset == .photo)
        #expect(config.cameraPosition == .back)
        #expect(config.includesAudio)
        #expect(config.includesVideoDataOutput)
        #expect(config.includesPhotoOutput)
        #expect(!config.includesMovieFileOutput)
        #expect(config.videoPixelFormat == kCVPixelFormatType_32BGRA)
        #expect(config.maxPhotoQualityPrioritization == .quality)
        #expect(config.enableResponsiveCapture)
        #expect(config.enableAutoDeferredPhotoDelivery)
        #expect(config.enableZeroShutterLag)
        #expect(!config.enableLivePhoto)
        #expect(!config.enableDepthDataDelivery)
        #expect(!config.enablePortraitEffectsMatteDelivery)
        #expect(config.preferredVideoStabilizationMode == .auto)
        #expect(!config.enableMultitaskingCameraAccess)
    }

    @Test
    func `Default device types include triple camera for iOS`() {
        let types = PRMCameraConfiguration.defaultDeviceTypes
        #expect(types.contains(.builtInTripleCamera))
        #expect(types.contains(.builtInWideAngleCamera))
    }

    @Test
    func `Custom configuration values are preserved`() {
        let config = PRMCameraConfiguration(
            sessionPreset: .hd1920x1080,
            cameraPosition: .front,
            includesAudio: false,
            enableZeroShutterLag: false,
            enableLivePhoto: true,
            enableDepthDataDelivery: true,
            enablePortraitEffectsMatteDelivery: true,
            preferredVideoStabilizationMode: .cinematic
        )
        #expect(config.sessionPreset == .hd1920x1080)
        #expect(config.cameraPosition == .front)
        #expect(!config.includesAudio)
        #expect(!config.enableZeroShutterLag)
        #expect(config.enableLivePhoto)
        #expect(config.enableDepthDataDelivery)
        #expect(config.enablePortraitEffectsMatteDelivery)
        #expect(config.preferredVideoStabilizationMode == .cinematic)
    }

    @Test
    func `iOS 26 and 27 options default to off`() {
        let config = PRMCameraConfiguration()
        #expect(config.deferredStart == .systemDefault)
        #expect(config.lensSmudgeDetectionInterval == nil)
        #expect(!config.enableBluetoothHighQualityRecording)
        #expect(!config.includesMetadataOutput)
        #expect(config.metadataObjectTypes.isEmpty)
        #expect(!config.enableCinematicVideo)
        #expect(config.enableCameraSensorOrientationCompensation == nil)
    }

    @Test
    func `Cinematic Video conflicts only warn`() {
        // validate() logs warnings for Cinematic Video + Live Photo / 48MP / depth, but must
        // not assert: those combinations are legal, AVFoundation just turns features off.
        let config = PRMCameraConfiguration(
            enableLivePhoto: true,
            enableDepthDataDelivery: true,
            enableCinematicVideo: true
        )
        // Returning (rather than tripping an assertion) is the check.
        config.validate()
    }
}
