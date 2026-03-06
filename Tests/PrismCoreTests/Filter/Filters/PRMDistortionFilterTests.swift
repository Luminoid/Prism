import CoreImage
import Testing
@testable import PrismCore

@Suite("PRMDistortionFilters")
struct PRMDistortionFilterTests {
    private let testImage = CIImage(color: .cyan).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    // MARK: - PRMBumpDistortionFilter

    @Test("Bump distortion renders non-nil")
    func bumpRenders() {
        let filter = PRMBumpDistortionFilter(radius: 50.0, scale: 0.3)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Bump distortion stores values")
    func bumpValues() {
        let filter = PRMBumpDistortionFilter(radius: 100.0, scale: -0.5)
        #expect(filter.radius == 100.0)
        #expect(filter.scale == -0.5)
    }

    @Test("Bump distortion defaults")
    func bumpDefaults() {
        let filter = PRMBumpDistortionFilter()
        #expect(filter.radius == 300.0)
        #expect(filter.scale == 0.5)
    }

    // MARK: - PRMTwirlDistortionFilter

    @Test("Twirl distortion renders non-nil")
    func twirlRenders() {
        let filter = PRMTwirlDistortionFilter(radius: 50.0, angle: 1.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Twirl distortion stores values")
    func twirlValues() {
        let filter = PRMTwirlDistortionFilter(radius: 200.0, angle: 3.14)
        #expect(filter.radius == 200.0)
        #expect(filter.angle == 3.14)
    }

    @Test("Twirl distortion defaults")
    func twirlDefaults() {
        let filter = PRMTwirlDistortionFilter()
        #expect(filter.radius == 300.0)
        #expect(filter.angle == Float.pi)
    }

    // MARK: - PRMPinchDistortionFilter

    @Test("Pinch distortion renders non-nil")
    func pinchRenders() {
        let filter = PRMPinchDistortionFilter(radius: 50.0, scale: 0.3)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Pinch distortion stores values")
    func pinchValues() {
        let filter = PRMPinchDistortionFilter(radius: 150.0, scale: 0.8)
        #expect(filter.radius == 150.0)
        #expect(filter.scale == 0.8)
    }

    @Test("Pinch distortion defaults")
    func pinchDefaults() {
        let filter = PRMPinchDistortionFilter()
        #expect(filter.radius == 300.0)
        #expect(filter.scale == 0.5)
    }

    // MARK: - PRMVortexDistortionFilter

    @Test("Vortex distortion renders non-nil")
    func vortexRenders() {
        let filter = PRMVortexDistortionFilter(radius: 50.0, angle: 10.0)
        #expect(filter.render(image: testImage) != nil)
    }

    @Test("Vortex distortion stores values")
    func vortexValues() {
        let filter = PRMVortexDistortionFilter(radius: 250.0, angle: 30.0)
        #expect(filter.radius == 250.0)
        #expect(filter.angle == 30.0)
    }

    @Test("Vortex distortion defaults")
    func vortexDefaults() {
        let filter = PRMVortexDistortionFilter()
        #expect(filter.radius == 300.0)
        #expect(filter.angle == 56.55)
    }
}
