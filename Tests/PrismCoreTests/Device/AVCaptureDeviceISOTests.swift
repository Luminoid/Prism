import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+ISO.swift`. ISO/shutter setters need a real device, so we
/// only lock the public surface here.
struct AVCaptureDeviceISOTests {
    @Test
    func `Public method signatures compile`() {
        let setISO: (AVCaptureDevice) -> (Float, (@Sendable (CMTime) -> Void)?) throws -> Void =
            { device in device.prm_setISO }
        let setShutter: (AVCaptureDevice) -> (Double, (@Sendable (CMTime) -> Void)?) throws -> Void =
            { device in device.prm_setShutterSpeed }
        let isoRange: (AVCaptureDevice) -> () -> ClosedRange<Float> =
            { device in device.prm_isoRange }
        let shutterRange: (AVCaptureDevice) -> () -> ClosedRange<Double> =
            { device in device.prm_shutterSpeedRange }
        _ = (setISO, setShutter, isoRange, shutterRange)
        #expect(true)
    }
}
