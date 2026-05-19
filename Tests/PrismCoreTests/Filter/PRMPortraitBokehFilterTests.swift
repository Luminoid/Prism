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
    func `Sendable across actor`() async {
        let matte = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let filter = PRMPortraitBokehFilter(matte: matte, radius: 2)
        let radius = await Task.detached { filter.radius }.value
        #expect(radius == 2)
    }
}
