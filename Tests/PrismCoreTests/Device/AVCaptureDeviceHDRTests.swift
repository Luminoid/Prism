import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+HDR.swift`. HDR / low-light setters need a real device, so we
/// only lock the public surface here.
struct AVCaptureDeviceHDRTests {
    @Test
    func `Public method signatures compile`() {
        let setHDR: (AVCaptureDevice) -> (Bool?) throws -> Void =
            { device in device.prm_setVideoHDR }
        let setLowLight: (AVCaptureDevice) -> (Bool) throws -> Void =
            { device in device.prm_setLowLightBoost }
        let isLowLight: (AVCaptureDevice) -> Bool =
            { device in device.prm_isLowLightBoostActive }
        _ = (setHDR, setLowLight, isLowLight)
        #expect(true)
    }
}
