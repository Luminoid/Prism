import CoreImage
import Testing
@testable import PrismCore

@Suite("PRMColorFilters")
struct PRMColorFilterTests {
    private let testImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    // MARK: - PRMBrightnessFilter

    @Test("Brightness filter renders non-nil")
    func brightnessRenders() {
        let filter = PRMBrightnessFilter(value: 0.5)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Brightness filter stores value")
    func brightnessValue() {
        let filter = PRMBrightnessFilter(value: -0.3)
        #expect(filter.value == -0.3)
    }

    @Test("Brightness filter default is 0")
    func brightnessDefault() {
        let filter = PRMBrightnessFilter()
        #expect(filter.value == 0.0)
    }

    // MARK: - PRMContrastFilter

    @Test("Contrast filter renders non-nil")
    func contrastRenders() {
        let filter = PRMContrastFilter(value: 1.5)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Contrast filter stores value")
    func contrastValue() {
        let filter = PRMContrastFilter(value: 2.0)
        #expect(filter.value == 2.0)
    }

    @Test("Contrast filter default is 1")
    func contrastDefault() {
        let filter = PRMContrastFilter()
        #expect(filter.value == 1.0)
    }

    // MARK: - PRMSaturationFilter

    @Test("Saturation filter renders non-nil")
    func saturationRenders() {
        let filter = PRMSaturationFilter(value: 0.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Saturation filter stores value")
    func saturationValue() {
        let filter = PRMSaturationFilter(value: 0.5)
        #expect(filter.value == 0.5)
    }

    @Test("Saturation filter default is 1")
    func saturationDefault() {
        let filter = PRMSaturationFilter()
        #expect(filter.value == 1.0)
    }

    // MARK: - PRMHueRotationFilter

    @Test("Hue rotation filter renders non-nil")
    func hueRotationRenders() {
        let filter = PRMHueRotationFilter(angle: .pi)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Hue rotation filter stores angle")
    func hueRotationAngle() {
        let filter = PRMHueRotationFilter(angle: 1.5)
        #expect(filter.angle == 1.5)
    }

    @Test("Hue rotation filter default is 0")
    func hueRotationDefault() {
        let filter = PRMHueRotationFilter()
        #expect(filter.angle == 0.0)
    }
}
