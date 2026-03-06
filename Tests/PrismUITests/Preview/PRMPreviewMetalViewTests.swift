import CoreGraphics
import Testing
@testable import PrismUI

// MARK: - PRMPreviewMetalViewRotationTests

@Suite("PRMPreviewMetalView.Rotation")
struct PRMPreviewMetalViewRotationTests {
    @Test("All rotation cases exist")
    func allCases() {
        let r0: PRMPreviewMetalView.Rotation = .rotate0Degrees
        let r90: PRMPreviewMetalView.Rotation = .rotate90Degrees
        let r180: PRMPreviewMetalView.Rotation = .rotate180Degrees
        let r270: PRMPreviewMetalView.Rotation = .rotate270Degrees
        #expect(r0.rawValue == 0)
        #expect(r90.rawValue == 1)
        #expect(r180.rawValue == 2)
        #expect(r270.rawValue == 3)
    }

    @Test("Rotation raw values are sequential")
    func sequentialRawValues() {
        #expect(PRMPreviewMetalView.Rotation.rotate0Degrees.rawValue == 0)
        #expect(PRMPreviewMetalView.Rotation.rotate90Degrees.rawValue == 1)
        #expect(PRMPreviewMetalView.Rotation.rotate180Degrees.rawValue == 2)
        #expect(PRMPreviewMetalView.Rotation.rotate270Degrees.rawValue == 3)
    }

    @Test("Rotation can be created from raw value")
    func fromRawValue() {
        #expect(PRMPreviewMetalView.Rotation(rawValue: 0) == .rotate0Degrees)
        #expect(PRMPreviewMetalView.Rotation(rawValue: 1) == .rotate90Degrees)
        #expect(PRMPreviewMetalView.Rotation(rawValue: 2) == .rotate180Degrees)
        #expect(PRMPreviewMetalView.Rotation(rawValue: 3) == .rotate270Degrees)
        #expect(PRMPreviewMetalView.Rotation(rawValue: 4) == nil)
    }
}

// MARK: - PRMPreviewMetalViewTests

@Suite("PRMPreviewMetalView")
@MainActor
struct PRMPreviewMetalViewTests {
    @Test("View initializes with zero frame")
    func initWithZeroFrame() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(view.frame == .zero)
    }

    @Test("View initializes with custom frame")
    func initWithCustomFrame() {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let view = PRMPreviewMetalView(frame: frame)
        #expect(view.frame == frame)
    }

    @Test("Default rotation is 0 degrees")
    func defaultRotation() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(view.rotation == .rotate0Degrees)
    }

    @Test("Default mirroring is false")
    func defaultMirroring() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(!view.mirroring)
    }

    @Test("Default pixel buffer is nil")
    func defaultPixelBuffer() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(view.pixelBuffer == nil)
    }

    @Test("Rotation can be set")
    func setRotation() {
        let view = PRMPreviewMetalView(frame: .zero)
        view.rotation = .rotate90Degrees
        #expect(view.rotation == .rotate90Degrees)
    }

    @Test("Mirroring can be set")
    func setMirroring() {
        let view = PRMPreviewMetalView(frame: .zero)
        view.mirroring = true
        #expect(view.mirroring)
    }

    @Test("Background is clear")
    func clearBackground() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(view.backgroundColor == .clear)
    }

    @Test("View is paused (manual draw only)")
    func isPaused() {
        let view = PRMPreviewMetalView(frame: .zero)
        #expect(view.isPaused)
    }

    // MARK: - Coordinate Transforms

    @Test("Texture point from view point returns a point")
    func texturePointFromView() {
        let view = PRMPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let point = view.texturePoint(fromViewPoint: CGPoint(x: 50, y: 50))
        // Without a drawn frame, transform may not be set — returns input point
        #expect(point.x >= 0)
        #expect(point.y >= 0)
    }

    @Test("View point from texture point returns a point")
    func viewPointFromTexture() {
        let view = PRMPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let point = view.viewPoint(fromTexturePoint: CGPoint(x: 0.5, y: 0.5))
        #expect(point.x >= 0)
        #expect(point.y >= 0)
    }

    // MARK: - Flush

    @Test("Flush texture cache does not crash")
    func flushTextureCache() {
        let view = PRMPreviewMetalView(frame: .zero)
        view.flushTextureCache()
    }
}
