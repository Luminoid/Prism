import CoreImage
import Testing
@testable import PrismCore

struct PRMPortraitBokehFilterTests {
    @Test
    func `Pass-through extent matches input`() {
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let matte = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let filter = PRMPortraitBokehFilter(matte: matte, radius: 0)
        let out = filter.render(source)
        #expect(out.extent == source.extent)
    }

    @Test
    func `Depth mode builds without an unknown-key exception`() {
        // CIDepthBlurEffect has no center key; passing one raised NSUnknownKeyException.
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let disparity = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let out = PRMPortraitBokehFilter(depthData: disparity, focusDistance: 0.3, radius: 4).render(source)
        #expect(out.extent == source.extent)
    }

    @Test
    func `Focus rect is normalized and stays in the frame`() {
        let middle = PRMPortraitBokehFilter.focusRect(forFocusDistance: 0.5)
        #expect(abs(middle.midX - 0.5) < 1e-9)
        #expect(abs(middle.midY - 0.5) < 1e-9)
        let top = PRMPortraitBokehFilter.focusRect(forFocusDistance: 2)
        #expect(top.maxY <= 1)
        let invalid = PRMPortraitBokehFilter.focusRect(forFocusDistance: .nan)
        #expect(abs(invalid.midY - 0.5) < 1e-9)
    }

    @Test
    func `Sendable across actor`() async {
        let matte = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let filter = PRMPortraitBokehFilter(matte: matte, radius: 2)
        let radius = await Task.detached { filter.radius }.value
        #expect(radius == 2)
    }
}
