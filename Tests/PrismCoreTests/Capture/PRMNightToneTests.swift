import CoreImage
import ImageIO
import Testing
@testable import PrismCore

/// `PRMNightTone`: statistics, gain, noise level, orientation, and the rendered result.
struct PRMNightToneTests {
    @Test
    func `Statistics give the geometric mean and the 99.5th percentile`() {
        let flat = PRMNightTone.stats(luminances: [Float](repeating: 0.1, count: 100))
        #expect(abs(flat.logAverage - 0.1) < 1e-5)
        #expect(abs(flat.highlight - 0.1) < 1e-6)
        // Two values a factor of 4 apart: geometric mean is their middle on a log scale.
        let pair = PRMNightTone.stats(luminances: [0.05, 0.2])
        #expect(abs(pair.logAverage - 0.1) < 1e-5)
        // One bright light among 999 dark pixels doesn't move the 99.5th percentile.
        let light = PRMNightTone.stats(luminances: [Float](repeating: 0.02, count: 999) + [8])
        #expect(light.highlight == 0.02)
        #expect(PRMNightTone.stats(luminances: []).logAverage == 0)
        #expect(PRMNightTone.stats(luminances: [.nan]).logAverage == 0)
    }

    @Test
    func `Gain lifts the key toward 0.12, capped by the frame count`() {
        // Two stops short, 16 frames allow 3 EV: the full two.
        #expect(abs(PRMNightTone.gainEV(key: 0.03, frameCount: 16) - 2) < 1e-5)
        // Very dark, 4 frames allow only 2 EV.
        #expect(PRMNightTone.gainEV(key: 0.001, frameCount: 4) == 2)
        // Never more than 3 EV.
        #expect(PRMNightTone.gainEV(key: 0.0001, frameCount: 64) == 3)
        // Already bright: no darkening.
        #expect(PRMNightTone.gainEV(key: 0.5, frameCount: 16) == 0)
        #expect(PRMNightTone.gainEV(key: 0, frameCount: 16) == 0)
        #expect(PRMNightTone.gainEV(key: .nan, frameCount: 16) == 0)
    }

    @Test
    func `Noise reduction rises with gain and falls with more frames, within bounds`() {
        let base = PRMNightTone.noiseLevel(gainEV: 1, frameCount: 16)
        #expect(PRMNightTone.noiseLevel(gainEV: 2, frameCount: 16) > base)
        #expect(PRMNightTone.noiseLevel(gainEV: 1, frameCount: 4) > base)
        #expect(PRMNightTone.noiseLevel(gainEV: 0, frameCount: 64) == 0.005)
        #expect(PRMNightTone.noiseLevel(gainEV: 3, frameCount: 1) == 0.04)
    }

    @Test
    func `Clockwise angles map to image orientations`() {
        #expect(PRMNightTone.orientation(forClockwiseDegrees: 0) == .up)
        #expect(PRMNightTone.orientation(forClockwiseDegrees: 90) == .right)
        #expect(PRMNightTone.orientation(forClockwiseDegrees: 180) == .down)
        #expect(PRMNightTone.orientation(forClockwiseDegrees: 270) == .left)
        #expect(PRMNightTone.orientation(forClockwiseDegrees: -90) == .left)
        #expect(PRMNightTone.orientation(forClockwiseDegrees: 450) == .right)
    }

    @Test
    func `Turning 90 degrees clockwise puts the left edge on top`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let image = twoPixels(left: .red, right: .blue)
        let turned = PRMNightTone.oriented(image, clockwiseDegrees: 90, mirrored: false)
        #expect(turned.extent == CGRect(x: 0, y: 0, width: 1, height: 2))
        // Core Image's origin is bottom-left: y = 1 is the top pixel.
        #expect(color(of: turned, x: 0, y: 1, context: context).red > 0.9)
        #expect(color(of: turned, x: 0, y: 0, context: context).blue > 0.9)
    }

    @Test
    func `Mirroring swaps left and right`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let mirrored = PRMNightTone.oriented(twoPixels(left: .red, right: .blue), clockwiseDegrees: 0, mirrored: true)
        #expect(mirrored.extent == CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(color(of: mirrored, x: 0, y: 0, context: context).blue > 0.9)
        #expect(color(of: mirrored, x: 1, y: 0, context: context).red > 0.9)
    }

    @Test
    func `Rendering brightens a dark merge and keeps its size`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let linearSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let gray = try #require(CIColor(red: 0.02, green: 0.02, blue: 0.02, colorSpace: linearSpace))
        let dark = CIImage(color: gray)
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let rendered = PRMNightTone.render(dark, gainEV: 2, highlight: 0.02, frameCount: 16)
        #expect(rendered.extent == dark.extent)
        let before = color(of: dark, x: 16, y: 16, context: context).red
        let after = color(of: rendered, x: 16, y: 16, context: context).red
        #expect(after > before * 2)
        #expect(after.isFinite)
    }

    // MARK: - Helpers

    private func twoPixels(left: CIColor, right: CIColor) -> CIImage {
        CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            .composited(over: CIImage(color: right).cropped(to: CGRect(x: 1, y: 0, width: 1, height: 1)))
    }

    /// One pixel in linear values, addressed in Core Image coordinates (origin bottom-left).
    private func color(of image: CIImage, x: Int, y: Int, context: CIContext) -> (red: Float, green: Float, blue: Float) {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        return (pixel[0], pixel[1], pixel[2])
    }
}
