import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

@Suite("PRMExposureHelper")
struct PRMExposureHelperTests {
    // MARK: - Query Signatures

    @Test("Exposure bias range returns ClosedRange")
    func exposureBiasRangeSignature() {
        let _: (AVCaptureDevice) -> ClosedRange<Float> = PRMExposureHelper.exposureBiasRange(for:)
    }

    @Test("ISO range returns ClosedRange")
    func isoRangeSignature() {
        let _: (AVCaptureDevice) -> ClosedRange<Float> = PRMExposureHelper.isoRange(for:)
    }

    @Test("Duration range returns tuple")
    func durationRangeSignature() {
        let _: (AVCaptureDevice) -> (min: CMTime, max: CMTime) = PRMExposureHelper.durationRange(for:)
    }

    @Test("Current exposure target bias returns Float")
    func currentExposureTargetBiasSignature() {
        let _: (AVCaptureDevice) -> Float = PRMExposureHelper.currentExposureTargetBias(for:)
    }

    @Test("Current ISO returns Float")
    func currentISOSignature() {
        let _: (AVCaptureDevice) -> Float = PRMExposureHelper.currentISO(for:)
    }

    @Test("Current exposure duration returns CMTime")
    func currentExposureDurationSignature() {
        let _: (AVCaptureDevice) -> CMTime = PRMExposureHelper.currentExposureDuration(for:)
    }

    // MARK: - Control Signatures

    @Test("Set exposure target bias method exists")
    func setExposureTargetBiasSignature() {
        // Verify four-parameter signature with optional completion
        typealias Method = (Float, AVCaptureDevice, (@Sendable (CMTime) -> Void)?) throws -> Void
        let _: Method = PRMExposureHelper.setExposureTargetBias(_:on:completion:)
    }

    @Test("Set exposure mode method exists")
    func setExposureModeSignature() {
        let _: (AVCaptureDevice.ExposureMode, AVCaptureDevice) throws -> Void =
            PRMExposureHelper.setExposureMode(_:on:)
    }

    @Test("Set custom exposure method exists")
    func setCustomExposureSignature() {
        typealias Method = (CMTime, Float, AVCaptureDevice, (@Sendable (CMTime) -> Void)?) throws -> Void
        let _: Method = PRMExposureHelper.setCustomExposure(duration:iso:on:completion:)
    }
}
