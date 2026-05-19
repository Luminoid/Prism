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
}
