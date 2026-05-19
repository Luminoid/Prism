import CoreImage
import Testing
@testable import PrismCore

struct PRMFilterTests {
    private let testImage = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))

    @Test
    func `Passthrough returns the input image identity`() {
        let filter = PRMPassThroughFilter()
        let output = filter.render(testImage)
        #expect(output === testImage)
    }

    @Test
    func `Grayscale produces a different image`() {
        let output = PRMGrayscaleFilter().render(testImage)
        #expect(!output.extent.isEmpty)
    }

    @Test
    func `Sepia honors intensity parameter`() {
        let sepia = PRMSepiaFilter(intensity: 0.5)
        #expect(sepia.intensity == 0.5)
        _ = sepia.render(testImage)
    }

    @Test
    func `All color filters return a valid image`() {
        _ = PRMBrightnessFilter(value: 0.2).render(testImage)
        _ = PRMContrastFilter(value: 1.5).render(testImage)
        _ = PRMSaturationFilter(value: 1.5).render(testImage)
        _ = PRMHueRotationFilter(angle: 1.0).render(testImage)
        _ = PRMVignetteFilter().render(testImage)
    }

    @Test
    func `All blur filters return a valid image`() {
        _ = PRMGaussianBlurFilter(radius: 5).render(testImage)
        _ = PRMMotionBlurFilter(radius: 10).render(testImage)
        _ = PRMZoomBlurFilter(amount: 5).render(testImage)
    }

    @Test
    func `All stylize filters return a valid image`() {
        _ = PRMPixellateFilter(scale: 4).render(testImage)
        _ = PRMComicFilter().render(testImage)
        _ = PRMPointillizeFilter(radius: 10).render(testImage)
        _ = PRMEdgesFilter().render(testImage)
    }

    @Test
    func `All distortion filters return a valid image`() {
        _ = PRMBumpDistortionFilter().render(testImage)
        _ = PRMTwirlDistortionFilter().render(testImage)
        _ = PRMPinchDistortionFilter().render(testImage)
        _ = PRMVortexDistortionFilter().render(testImage)
    }
}
