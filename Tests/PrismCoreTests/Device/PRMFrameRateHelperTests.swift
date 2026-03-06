import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMFrameRateHelper")
struct PRMFrameRateHelperTests {
    // MARK: - FrameRateRange

    @Test("FrameRateRange stores values")
    func frameRateRangeInit() {
        let range = PRMFrameRateHelper.FrameRateRange(minFrameRate: 24, maxFrameRate: 60)
        #expect(range.minFrameRate == 24)
        #expect(range.maxFrameRate == 60)
    }

    @Test("FrameRateRange with slow-motion values")
    func frameRateRangeSlowMotion() {
        let range = PRMFrameRateHelper.FrameRateRange(minFrameRate: 1, maxFrameRate: 240)
        #expect(range.maxFrameRate >= 120)
    }

    // MARK: - Query Signatures

    @Test("Supported frame rate ranges returns array")
    func supportedFrameRateRangesSignature() {
        let _: (AVCaptureDevice) -> [PRMFrameRateHelper.FrameRateRange] =
            PRMFrameRateHelper.supportedFrameRateRanges(for:)
    }

    @Test("All supported frame rate ranges returns array")
    func allSupportedFrameRateRangesSignature() {
        let _: (AVCaptureDevice) -> [PRMFrameRateHelper.FrameRateRange] =
            PRMFrameRateHelper.allSupportedFrameRateRanges(for:)
    }

    @Test("Supports slow motion returns Bool")
    func supportsSlowMotionSignature() {
        let _: (AVCaptureDevice) -> Bool = PRMFrameRateHelper.supportsSlowMotion(on:)
    }

    @Test("Supports frame rate returns Bool")
    func supportsFrameRateSignature() {
        let _: (Float64, AVCaptureDevice) -> Bool = PRMFrameRateHelper.supportsFrameRate(_:on:)
    }

    @Test("Max supported frame rate returns Float64")
    func maxSupportedFrameRateSignature() {
        let _: (AVCaptureDevice) -> Float64 = PRMFrameRateHelper.maxSupportedFrameRate(for:)
    }

    // MARK: - Control Signatures

    @Test("Set frame rate method exists")
    func setFrameRateSignature() {
        let _: (Float64, AVCaptureDevice) throws -> Void = PRMFrameRateHelper.setFrameRate(_:on:)
    }

    @Test("Reset to default frame rate method exists")
    func resetToDefaultFrameRateSignature() {
        let _: (AVCaptureDevice) throws -> Void = PRMFrameRateHelper.resetToDefaultFrameRate(on:)
    }
}
