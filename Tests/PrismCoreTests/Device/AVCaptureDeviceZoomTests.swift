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
        #expect(true)
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
}
