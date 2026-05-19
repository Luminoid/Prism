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
        let setLensAsync: (AVCaptureDevice) -> (Float) async throws -> Void =
            { device in device.prm_setLensPosition }
        let setLensSync: (AVCaptureDevice) -> (Float, (@Sendable (CMTime) -> Void)?) throws -> Void =
            { device in device.prm_setLensPositionAsync }
        _ = (setFocusMode, setLensAsync, setLensSync)
        #expect(true)
    }
}
