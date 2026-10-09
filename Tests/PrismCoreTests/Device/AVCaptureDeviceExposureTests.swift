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
            (AVCaptureDevice.FocusMode, AVCaptureDevice.ExposureMode?, CGPoint, Bool) throws -> Void =
            { device in device.prm_setFocusAndExposure }
        let manualCapture: KeyPath<AVCaptureDevice, Bool> = \.prm_supportsManualExposureCapture
        _ = (setMode, setBias, setCustom, focusExp, manualCapture)
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

    @Test
    func `Rect of interest stays inside the unit square`() {
        let clamped = AVCaptureDevice.prm_clampedRectOfInterest(
            CGRect(x: 0.9, y: -0.2, width: 0.3, height: 0.3),
            minimumSize: .zero
        )
        #expect(clamped.minX >= 0 && clamped.maxX <= 1)
        #expect(clamped.minY >= 0 && clamped.maxY <= 1)
        #expect(clamped.width == 0.3)
        #expect(clamped.height == 0.3)
    }

    @Test
    func `Rect of interest grows to the minimum size around its center`() {
        let clamped = AVCaptureDevice.prm_clampedRectOfInterest(
            CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
            minimumSize: CGSize(width: 0.2, height: 0.25)
        )
        #expect(abs(clamped.width - 0.2) < 1e-9)
        #expect(abs(clamped.height - 0.25) < 1e-9)
        #expect(abs(clamped.midX - 0.5) < 1e-9)
        #expect(abs(clamped.midY - 0.5) < 1e-9)
    }

    @Test
    func `Oversized and inverted rects are normalized`() {
        let full = AVCaptureDevice.prm_clampedRectOfInterest(CGRect(x: -1, y: -1, width: 3, height: 3), minimumSize: .zero)
        #expect(full == CGRect(x: 0, y: 0, width: 1, height: 1))
        let inverted = AVCaptureDevice.prm_clampedRectOfInterest(CGRect(x: 0.6, y: 0.6, width: -0.2, height: -0.2), minimumSize: .zero)
        #expect(abs(inverted.minX - 0.4) < 1e-9)
        #expect(abs(inverted.width - 0.2) < 1e-9)
    }

    @Test
    func `iOS 26 focus signatures compile`() {
        let rect: (AVCaptureDevice) -> (AVCaptureDevice.FocusMode, AVCaptureDevice.ExposureMode?, CGRect, Bool) throws -> Void =
            { device in device.prm_setFocusAndExposure }
        let defaultRect: (AVCaptureDevice) -> (CGPoint) -> CGRect? = { device in device.prm_defaultFocusRect }
        let exposureOnly: (AVCaptureDevice) -> (CGPoint, AVCaptureDevice.ExposureMode) throws -> Void =
            { device in device.prm_setExposurePointOfInterest }
        _ = (rect, defaultRect, exposureOnly)
    }

    @Test
    func `Shutter clamping returns the format's own bound`() {
        let lower = CMTime(value: 134, timescale: 10_000_000) // 13.4 µs
        let upper = CMTime(value: 1, timescale: 1)
        // Re-quantizing through seconds at timescale 1_000_000 rounded this to 13 µs,
        // below the minimum, which makes setExposureModeCustom raise.
        let tooShort = CMTime(value: 10, timescale: 1_000_000)
        #expect(CMTimeCompare(AVCaptureDevice.prm_clampedDuration(tooShort, min: lower, max: upper), lower) == 0)
        // A coarse timescale no longer collapses to zero.
        let coarse = CMTime(value: 0, timescale: 1)
        #expect(CMTimeCompare(AVCaptureDevice.prm_clampedDuration(coarse, min: lower, max: upper), lower) == 0)
        let tooLong = CMTime(value: 5, timescale: 1)
        #expect(CMTimeCompare(AVCaptureDevice.prm_clampedDuration(tooLong, min: lower, max: upper), upper) == 0)
        let inside = CMTime(value: 1, timescale: 250)
        #expect(CMTimeCompare(AVCaptureDevice.prm_clampedDuration(inside, min: lower, max: upper), inside) == 0)
        #expect(CMTimeCompare(AVCaptureDevice.prm_clampedDuration(.invalid, min: lower, max: upper), lower) == 0)
    }
}
