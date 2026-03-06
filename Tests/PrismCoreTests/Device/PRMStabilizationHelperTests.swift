import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMStabilizationHelper")
struct PRMStabilizationHelperTests {
    // MARK: - Query Signatures

    @Test("Is stabilization supported returns Bool")
    func isStabilizationSupportedSignature() {
        let _: (AVCaptureConnection) -> Bool = PRMStabilizationHelper.isStabilizationSupported(on:)
    }

    @Test("Active stabilization mode returns mode")
    func activeStabilizationModeSignature() {
        let _: (AVCaptureConnection) -> AVCaptureVideoStabilizationMode =
            PRMStabilizationHelper.activeStabilizationMode(on:)
    }

    @Test("Preferred stabilization mode returns mode")
    func preferredStabilizationModeSignature() {
        let _: (AVCaptureConnection) -> AVCaptureVideoStabilizationMode =
            PRMStabilizationHelper.preferredStabilizationMode(on:)
    }

    // MARK: - Control Signatures

    @Test("Set preferred stabilization mode method exists")
    func setPreferredStabilizationModeSignature() {
        let _: (AVCaptureVideoStabilizationMode, AVCaptureConnection) -> Void =
            PRMStabilizationHelper.setPreferredStabilizationMode(_:on:)
    }

    // MARK: - Stabilization Modes

    @Test("AVCaptureVideoStabilizationMode has expected cases")
    func stabilizationModes() {
        // Verify the modes we support are available
        let modes: [AVCaptureVideoStabilizationMode] = [.off, .standard, .cinematic, .auto]
        #expect(modes.count == 4)
    }
}
