import CoreImage
import Testing
@testable import PrismCore

@Suite("PRMStylizeFilters")
struct PRMStylizeFilterTests {
    private let testImage = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    // MARK: - PRMPixellateFilter

    @Test("Pixellate renders non-nil")
    func pixellateRenders() {
        let filter = PRMPixellateFilter(scale: 4.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Pixellate stores scale")
    func pixellateScale() {
        let filter = PRMPixellateFilter(scale: 16.0)
        #expect(filter.scale == 16.0)
    }

    @Test("Pixellate default scale is 8")
    func pixellateDefault() {
        let filter = PRMPixellateFilter()
        #expect(filter.scale == 8.0)
    }

    // MARK: - PRMComicFilter

    @Test("Comic filter renders non-nil")
    func comicRenders() {
        let filter = PRMComicFilter()
        #expect(filter.render(image: testImage) != nil)
    }

    // MARK: - PRMPointillizeFilter

    @Test("Pointillize renders non-nil")
    func pointillizeRenders() {
        let filter = PRMPointillizeFilter(radius: 10.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Pointillize stores radius")
    func pointillizeRadius() {
        let filter = PRMPointillizeFilter(radius: 30.0)
        #expect(filter.radius == 30.0)
    }

    @Test("Pointillize default radius is 20")
    func pointillizeDefault() {
        let filter = PRMPointillizeFilter()
        #expect(filter.radius == 20.0)
    }

    // MARK: - PRMEdgesFilter

    @Test("Edges renders non-nil")
    func edgesRenders() {
        let filter = PRMEdgesFilter(intensity: 2.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Edges stores intensity")
    func edgesIntensity() {
        let filter = PRMEdgesFilter(intensity: 3.0)
        #expect(filter.intensity == 3.0)
    }

    @Test("Edges default intensity is 1")
    func edgesDefault() {
        let filter = PRMEdgesFilter()
        #expect(filter.intensity == 1.0)
    }
}
