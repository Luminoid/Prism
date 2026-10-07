import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Aperture.swift`. The setters need a real device (and iOS 27
/// variable-aperture hardware for the aperture axis); coverage is via the Example app's
/// priority-mode rows. These lock the public surface.
struct AVCaptureDeviceApertureTests {
    @Test
    func `Public signatures compile`() {
        let setExposure: (AVCaptureDevice) -> (
            PRMExposureValue<Float>, PRMExposureValue<Double>, PRMExposureValue<Float>, (@Sendable (CMTime) -> Void)?
        ) throws -> Void = { device in device.prm_setExposure }
        let supports: (AVCaptureDevice) -> (PRMExposureValue<Float>, PRMExposureValue<Double>, PRMExposureValue<Float>) -> Bool =
            { device in device.prm_supportsExposure }
        let rateLimit: (AVCaptureDevice) -> (Float) throws -> Void = { device in device.prm_setAutoApertureRateLimit }
        let signals: (AVCaptureDevice) -> (Set<PRMExposureSignal>?) throws -> Void = { device in device.prm_setExposureSignals }
        let range: KeyPath<AVCaptureDevice, ClosedRange<Float>?> = \.prm_lensApertureRange
        let axes: KeyPath<AVCaptureDevice, PRMExposureAxes> = \.prm_autoExposureAxes
        let active: KeyPath<AVCaptureDevice, Set<PRMExposureSignal>> = \.prm_activeExposureSignals
        _ = (setExposure, supports, rateLimit, signals, range, axes, active)
    }
}
