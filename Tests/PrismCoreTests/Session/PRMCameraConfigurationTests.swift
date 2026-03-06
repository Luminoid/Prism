import AVFoundation
import Testing
@testable import PrismCore

// MARK: - PRMCameraConfigurationTests

@Suite("PRMCameraConfiguration")
struct PRMCameraConfigurationTests {
    // MARK: - Defaults

    @Test("Default session preset is photo")
    func defaultPreset() {
        let config = PRMCameraConfiguration()
        #expect(config.sessionPreset == .photo)
    }

    @Test("Default camera position is back")
    func defaultPosition() {
        let config = PRMCameraConfiguration()
        #expect(config.cameraPosition == .back)
    }

    @Test("Default includes audio")
    func defaultIncludesAudio() {
        let config = PRMCameraConfiguration()
        #expect(config.includesAudio)
    }

    @Test("Default includes video data output")
    func defaultIncludesVideoData() {
        let config = PRMCameraConfiguration()
        #expect(config.includesVideoDataOutput)
    }

    @Test("Default includes photo output")
    func defaultIncludesPhoto() {
        let config = PRMCameraConfiguration()
        #expect(config.includesPhotoOutput)
    }

    @Test("Default pixel format is 32BGRA")
    func defaultPixelFormat() {
        let config = PRMCameraConfiguration()
        #expect(config.videoPixelFormat == kCVPixelFormatType_32BGRA)
    }

    // MARK: - Custom Values

    @Test("Custom session preset")
    func customPreset() {
        let config = PRMCameraConfiguration(sessionPreset: .hd1920x1080)
        #expect(config.sessionPreset == .hd1920x1080)
    }

    @Test("Custom camera position")
    func customPosition() {
        let config = PRMCameraConfiguration(cameraPosition: .front)
        #expect(config.cameraPosition == .front)
    }

    @Test("Custom audio disabled")
    func audioDisabled() {
        let config = PRMCameraConfiguration(includesAudio: false)
        #expect(!config.includesAudio)
    }

    @Test("Custom video data output disabled")
    func videoDataDisabled() {
        let config = PRMCameraConfiguration(includesVideoDataOutput: false)
        #expect(!config.includesVideoDataOutput)
    }

    @Test("Custom photo output disabled")
    func photoOutputDisabled() {
        let config = PRMCameraConfiguration(includesPhotoOutput: false)
        #expect(!config.includesPhotoOutput)
    }
}
