import CoreImage
import Testing
@testable import PrismCore

@Suite("PRMBlurFilters")
struct PRMBlurFilterTests {
    private let testImage = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    // MARK: - PRMGaussianBlurFilter

    @Test("Gaussian blur renders non-nil")
    func gaussianBlurRenders() {
        let filter = PRMGaussianBlurFilter(radius: 5.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Gaussian blur stores radius")
    func gaussianBlurRadius() {
        let filter = PRMGaussianBlurFilter(radius: 15.0)
        #expect(filter.radius == 15.0)
    }

    @Test("Gaussian blur default radius is 10")
    func gaussianBlurDefault() {
        let filter = PRMGaussianBlurFilter()
        #expect(filter.radius == 10.0)
    }

    // MARK: - PRMMotionBlurFilter

    @Test("Motion blur renders non-nil")
    func motionBlurRenders() {
        let filter = PRMMotionBlurFilter(radius: 10.0, angle: 0.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Motion blur stores radius and angle")
    func motionBlurValues() {
        let filter = PRMMotionBlurFilter(radius: 25.0, angle: 1.5)
        #expect(filter.radius == 25.0)
        #expect(filter.angle == 1.5)
    }

    @Test("Motion blur defaults")
    func motionBlurDefaults() {
        let filter = PRMMotionBlurFilter()
        #expect(filter.radius == 20.0)
        #expect(filter.angle == 0.0)
    }

    // MARK: - PRMZoomBlurFilter

    @Test("Zoom blur renders non-nil")
    func zoomBlurRenders() {
        let filter = PRMZoomBlurFilter(amount: 10.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Zoom blur stores amount")
    func zoomBlurAmount() {
        let filter = PRMZoomBlurFilter(amount: 30.0)
        #expect(filter.amount == 30.0)
    }

    @Test("Zoom blur default amount is 20")
    func zoomBlurDefault() {
        let filter = PRMZoomBlurFilter()
        #expect(filter.amount == 20.0)
    }
}
