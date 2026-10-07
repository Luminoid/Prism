import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+FocusTracking.swift`. Tracking needs iOS 27 hardware plus a
/// metadata output; the pure clamp and the public surface are covered here.
struct AVCaptureDeviceFocusTrackingTests {
    @Test
    func `Bias clamps to -1...1`() {
        #expect(AVCaptureDevice.prm_clampedTrackingBias(0.4) == 0.4)
        #expect(AVCaptureDevice.prm_clampedTrackingBias(3) == 1)
        #expect(AVCaptureDevice.prm_clampedTrackingBias(-3) == -1)
    }

    @Test
    func `Non-finite bias becomes zero`() {
        #expect(AVCaptureDevice.prm_clampedTrackingBias(.nan) == 0)
        #expect(AVCaptureDevice.prm_clampedTrackingBias(.infinity) == 0)
    }

    @Test
    func `Public signatures compile`() {
        let toggle: (AVCaptureDevice) -> (Bool) throws -> Void = { device in device.prm_setContinuousAutoFocusTracking }
        let bias: (AVCaptureDevice) -> (Float, CGPoint?) throws -> Void = { device in device.prm_setContinuousAutoFocusTrackingBias }
        let supported: KeyPath<AVCaptureDevice, Bool> = \.prm_isContinuousAutoFocusTrackingSupported
        let enabled: KeyPath<AVCaptureDevice, Bool> = \.prm_isContinuousAutoFocusTrackingEnabled
        let acquired: KeyPath<AVCaptureDevice, Bool> = \.prm_isContinuousAutoFocusTrackingSubjectAcquired
        _ = (toggle, bias, supported, enabled, acquired)
    }
}
