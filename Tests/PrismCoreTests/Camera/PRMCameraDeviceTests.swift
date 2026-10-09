import AVFoundation
import Testing
@testable import PrismCore

/// `PRMCameraDevice`'s `==` is synthesized (the photo dimensions are stored as the
/// Equatable `PRMVideoDimensions`), so every field takes part without a hand-kept list.
struct PRMCameraDeviceTests {
    private func makeDevice(
        maxSupportedPhotoDimensions: CMVideoDimensions? = nil,
        supportsCinematicVideo: Bool = false,
        cinematicVideoDeviceType: AVCaptureDevice.DeviceType? = nil,
        supportedWhiteBalanceModes: [AVCaptureDevice.WhiteBalanceMode] = AVCaptureDevice.WhiteBalanceMode.prm_allCases
    ) -> PRMCameraDevice {
        PRMCameraDevice(
            uniqueID: "id",
            deviceType: .builtInWideAngleCamera,
            position: .back,
            localizedName: "Back Camera",
            minZoomFactor: 1,
            maxZoomFactor: 10,
            switchOverZoomFactors: [],
            lenses: [],
            hasTorch: true,
            hasFlash: true,
            exposureBiasRange: -8 ... 8,
            isoRange: 32 ... 3200,
            shutterRange: 0.0001 ... 1,
            supportsCustomWhiteBalance: true,
            supportsSlowMotion: true,
            maxFrameRate: 240,
            maxSupportedPhotoDimensions: maxSupportedPhotoDimensions,
            supportsCinematicVideo: supportsCinematicVideo,
            cinematicVideoDeviceType: cinematicVideoDeviceType,
            supportedWhiteBalanceModes: supportedWhiteBalanceModes
        )
    }

    @Test
    func `New capabilities default to unsupported`() {
        let device = makeDevice()
        #expect(device.apertureRange == nil)
        #expect(device.recommendedApertureStops.isEmpty)
        #expect(!device.supportsFocusRectOfInterest)
        #expect(!device.supportsPrimaryConstituentLock)
        #expect(!device.supportsLowLightVideoNoiseReduction)
        #expect(!device.supportsContinuousAutoFocusTracking)
        #expect(device.simulatedApertureRange == nil)
        #expect(device.cinematicFrameRateRange == nil)
        #expect(device.cinematicVideoDeviceType == nil)
        #expect(device.maxSupportedPhotoDimensions == nil)
        #expect(!device.supportsLowLightBoost)
        #expect(!device.supportsVideoHDR)
    }

    @Test
    func `The Cinematic Video camera is this one when it has a Cinematic format`() {
        #expect(makeDevice(supportsCinematicVideo: true).cinematicVideoDeviceType == .builtInWideAngleCamera)
        // A Pro iPhone's Triple camera: Cinematic Video runs on the Dual Wide camera instead.
        let other = makeDevice(cinematicVideoDeviceType: .builtInDualWideCamera)
        #expect(!other.supportsCinematicVideo)
        #expect(other.cinematicVideoDeviceType == .builtInDualWideCamera)
    }

    @Test
    func `Photo dimensions round-trip and take part in equality`() {
        let fortyEight = makeDevice(maxSupportedPhotoDimensions: CMVideoDimensions(width: 8064, height: 6048))
        #expect(fortyEight.maxSupportedPhotoDimensions?.width == 8064)
        #expect(fortyEight.maxSupportedPhotoDimensions?.height == 6048)
        #expect(fortyEight == makeDevice(maxSupportedPhotoDimensions: CMVideoDimensions(width: 8064, height: 6048)))
        #expect(fortyEight != makeDevice(maxSupportedPhotoDimensions: CMVideoDimensions(width: 4032, height: 3024)))
        #expect(fortyEight != makeDevice())
    }

    @Test
    func `Supported modes default to every mode and take part in equality`() {
        let device = makeDevice()
        #expect(device.supportedExposureModes == [.locked, .autoExpose, .continuousAutoExposure, .custom])
        #expect(device.supportedWhiteBalanceModes == [.locked, .autoWhiteBalance, .continuousAutoWhiteBalance])
        #expect(device.supportedFocusModes == [.locked, .autoFocus, .continuousAutoFocus])
        // An iPhone camera: no one-shot auto white balance.
        let iPhone = makeDevice(supportedWhiteBalanceModes: [.locked, .continuousAutoWhiteBalance])
        #expect(!iPhone.supportedWhiteBalanceModes.contains(.autoWhiteBalance))
        #expect(iPhone != device)
    }
}
