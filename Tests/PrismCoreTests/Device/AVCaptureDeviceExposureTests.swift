import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Exposure.swift`.
///
/// `prm_setExposureMode`, `prm_setExposureBias`, `prm_setCustomExposure`, and
/// `prm_setFocusAndExposure` all require a real `AVCaptureDevice`. Coverage is via the
/// example app's vertical-drag EV control and tap-to-focus. We lock the public surface
/// here so accidental signature drift breaks the build.
struct AVCaptureDeviceExposureTests {
    @Test
    func `Public method signatures compile`() {
        let setMode: (AVCaptureDevice) -> (AVCaptureDevice.ExposureMode) throws -> Void =
            { device in device.prm_setExposureMode }
        let setBias: (AVCaptureDevice) -> (Float, (@Sendable (CMTime) -> Void)?) throws -> Void =
            { device in device.prm_setExposureBias }
        let setCustom: (AVCaptureDevice) -> (CMTime, Float, (@Sendable (CMTime) -> Void)?) throws -> Void =
            { device in device.prm_setCustomExposure }
        let focusExp: (AVCaptureDevice) ->
            (AVCaptureDevice.FocusMode, AVCaptureDevice.ExposureMode, CGPoint, Bool) throws -> Void =
            { device in device.prm_setFocusAndExposure }
        _ = (setMode, setBias, setCustom, focusExp)
        #expect(true)
    }

    @Test
    func `Common device-space focus points fall in 0...1`() {
        // Tap-to-focus contract: device-space points are (0,0) top-left, (1,1) bottom-right.
        // Pin a few canonical points so any future helpers that compute them have a reference.
        let center = CGPoint(x: 0.5, y: 0.5)
        let topLeft = CGPoint(x: 0, y: 0)
        let bottomRight = CGPoint(x: 1, y: 1)
        for point in [center, topLeft, bottomRight] {
            #expect(point.x >= 0 && point.x <= 1)
            #expect(point.y >= 0 && point.y <= 1)
        }
    }
}
