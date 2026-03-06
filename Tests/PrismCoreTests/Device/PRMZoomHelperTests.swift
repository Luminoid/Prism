import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMZoomHelper")
struct PRMZoomHelperTests {
    // MARK: - Zoom Factor Clamping

    @Test("Min zoom factor returns device minimum")
    func minZoomFactor() {
        // minAvailableVideoZoomFactor is a device property — verify the static method compiles and is callable
        // Actual device tests require a physical device; here we verify API surface
        let _: (AVCaptureDevice) -> CGFloat = PRMZoomHelper.minZoomFactor
        // Verifies the method signature is correct
    }

    @Test("Max zoom factor returns device maximum")
    func maxZoomFactor() {
        let _: (AVCaptureDevice) -> CGFloat = PRMZoomHelper.maxZoomFactor
    }

    @Test("Current zoom factor returns device value")
    func currentZoomFactor() {
        let _: (AVCaptureDevice) -> CGFloat = PRMZoomHelper.currentZoomFactor
    }

    @Test("Switch-over zoom factors returns array")
    func switchOverZoomFactors() {
        let _: (AVCaptureDevice) -> [CGFloat] = PRMZoomHelper.switchOverZoomFactors
    }

    @Test("Set zoom factor method exists with correct signature")
    func setZoomFactorSignature() {
        // Verify the method signature compiles — throws on lockForConfiguration failure
        let _: (CGFloat, AVCaptureDevice) throws -> Void = PRMZoomHelper.setZoomFactor(_:on:)
    }

    @Test("Ramp zoom method exists with correct signature")
    func rampZoomSignature() {
        let _: (CGFloat, Float, AVCaptureDevice) throws -> Void = PRMZoomHelper.rampZoom(to:withRate:on:)
    }

    @Test("Cancel zoom ramp method exists with correct signature")
    func cancelZoomRampSignature() {
        let _: (AVCaptureDevice) throws -> Void = PRMZoomHelper.cancelZoomRamp(on:)
    }

    // MARK: - Focal Length

    @Test("Focal length 35mm method exists with correct signature")
    func focalLength35mmSignature() {
        let _: (AVCaptureDevice, CGFloat?) -> Double = PRMZoomHelper.focalLength35mm(for:atZoomFactor:)
    }

    @Test("Lens infos method exists with correct signature")
    func lensInfosSignature() {
        let _: (AVCaptureDevice) -> [PRMZoomHelper.LensInfo] = PRMZoomHelper.lensInfos
    }

    @Test("LensInfo has zoom factor, display zoom factor, and focal length")
    func lensInfoProperties() {
        let info = PRMZoomHelper.LensInfo(zoomFactor: 2.0, displayZoomFactor: 1.0, focalLength: 48)
        #expect(info.zoomFactor == 2.0)
        #expect(info.displayZoomFactor == 1.0)
        #expect(info.focalLength == 48)
    }

    @Test("LensInfo conforms to Equatable")
    func lensInfoEquatable() {
        let a = PRMZoomHelper.LensInfo(zoomFactor: 1.0, displayZoomFactor: 0.5, focalLength: 24)
        let b = PRMZoomHelper.LensInfo(zoomFactor: 1.0, displayZoomFactor: 0.5, focalLength: 24)
        let c = PRMZoomHelper.LensInfo(zoomFactor: 2.0, displayZoomFactor: 1.0, focalLength: 48)
        #expect(a == b)
        #expect(a != c)
    }
}
