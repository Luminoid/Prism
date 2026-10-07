import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Zoom.swift`.
///
/// All four entry points (`prm_setZoom`, `prm_rampZoom`, `prm_cancelZoomRamp`,
/// `prm_focalLength35mm`, `prm_lenses`) require a real `AVCaptureDevice` — the simulator
/// doesn't surface one. Coverage is via the example app's lens picker and the manual test
/// plan. Here we lock the API surface so accidental renames or signature changes break the
/// test build immediately.
struct AVCaptureDeviceZoomTests {
    @Test
    func `Public method signatures compile`() {
        // We can't *call* these without a device, but we can ensure the symbols exist with
        // the documented signatures. `let _: <Type> = <method-reference>` is a compile-time
        // assertion that doesn't execute the method.
        let setZoom: (AVCaptureDevice) -> (CGFloat) throws -> Void = { device in device.prm_setZoom }
        let rampZoom: (AVCaptureDevice) -> (CGFloat, Float) throws -> Void = { device in device.prm_rampZoom }
        let cancelRamp: (AVCaptureDevice) -> () throws -> Void = { device in device.prm_cancelZoomRamp }
        let lenses: (AVCaptureDevice) -> () -> [PRMLens] = { device in device.prm_lenses }
        let focal: (AVCaptureDevice) -> (CGFloat?) -> Double = { device in device.prm_focalLength35mm }
        _ = (setZoom, rampZoom, cancelRamp, lenses, focal)
    }

    @Test
    func `Standard focal lengths include canonical phone-camera values`() {
        // Pinning the seed set so a future tweak to PRMLens.standardFocalLengths surfaces.
        // Values added later are fine; removing canonical ones (24mm wide, 77mm tele) is not.
        let standard = Set(PRMLens.standardFocalLengths)
        let canonical: [Int] = [13, 15, 24, 26, 48, 52, 65, 77, 120]
        for value in canonical {
            #expect(standard.contains(value), "Missing canonical focal length \(value)mm")
        }
    }

    @Test
    func `Nominal focal length scales from the widest lens at or below the factor`() {
        let lenses = [
            AVCaptureDevice.PRMLensFocalLength(factor: 1, nominal: 13),
            AVCaptureDevice.PRMLensFocalLength(factor: 2, nominal: 24),
            AVCaptureDevice.PRMLensFocalLength(factor: 8, nominal: 120),
        ]
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 1, physicalLenses: lenses) == 13)
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 2, physicalLenses: lenses) == 24)
        // 2× native crop of the 24 mm wide (raw 4.0) reads 48 mm.
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 4, physicalLenses: lenses) == 48)
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 8, physicalLenses: lenses) == 120)
    }

    @Test
    func `Nominal focal length is nil without nominal values`() {
        // Before iOS 26 (and on virtual devices) every nominal value is 0.
        let lenses = [
            AVCaptureDevice.PRMLensFocalLength(factor: 1, nominal: 0),
            AVCaptureDevice.PRMLensFocalLength(factor: 2, nominal: 0),
        ]
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 2, physicalLenses: lenses) == nil)
        let wide = [AVCaptureDevice.PRMLensFocalLength(factor: 1, nominal: 24)]
        #expect(AVCaptureDevice.prm_nominalFocalLength(atZoomFactor: 0.5, physicalLenses: wide) == nil)
    }

    @Test
    func `Display zoom uses the device multiplier`() {
        // Triple / DualWide: raw 2.0 (the wide lens) reads 1×.
        #expect(AVCaptureDevice.prm_displayZoomMultiplier(reported: 0.5, firstSwitchOver: 2) == 0.5)
        // Dual (wide + telephoto) starts at the wide lens: raw 1.0 reads 1×, not 0.5×.
        #expect(AVCaptureDevice.prm_displayZoomMultiplier(reported: 1, firstSwitchOver: 2) == 1)
        // No usable multiplier: fall back to treating the first switch-over as 1×.
        #expect(AVCaptureDevice.prm_displayZoomMultiplier(reported: 0, firstSwitchOver: 2) == 0.5)
    }

    @Test
    func `Lens lock signatures compile`() {
        let lock: (AVCaptureDevice) -> (AVCaptureDevice.DeviceType?) throws -> Void = { device in device.prm_lockPrimaryConstituent }
        let locked: KeyPath<AVCaptureDevice, Bool> = \.prm_isPrimaryConstituentLocked
        let nominal: KeyPath<AVCaptureDevice, Double> = \.prm_nominalFocalLength35mm
        _ = (lock, locked, nominal)
    }
}
