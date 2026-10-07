import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Lens.swift`. Manual-focus setters need a real device, so we
/// only lock the public surface here.
struct AVCaptureDeviceLensTests {
    @Test
    func `Public method signatures compile`() {
        let setFocusMode: (AVCaptureDevice) -> (AVCaptureDevice.FocusMode) throws -> Void =
            { device in device.prm_setFocusMode }
        let setLensAwaiting: (AVCaptureDevice) -> (Float, TimeInterval) async throws -> Void =
            { device in device.prm_setLensPosition }
        let setLensWithCompletion: (AVCaptureDevice) -> (Float, @escaping @Sendable (CMTime) -> Void) throws -> Void =
            { device in device.prm_setLensPosition }
        let supportsCustom: KeyPath<AVCaptureDevice, Bool> = \.prm_supportsCustomLensPosition
        _ = (setFocusMode, setLensAwaiting, setLensWithCompletion, supportsCustom)
    }
}
