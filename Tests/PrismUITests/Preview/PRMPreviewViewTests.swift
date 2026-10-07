import CoreVideo
import Foundation
import PrismCore
import Testing
@testable import PrismUI

@MainActor
struct PRMPreviewViewTests {
    @Test
    func `Default content fit is fill`() {
        let preview = PRMPreviewView()
        #expect(preview.contentFit == .fill)
    }

    @Test
    func `Mirroring defaults off; rotation defaults 0°`() {
        let preview = PRMPreviewView()
        #expect(!preview.mirroring)
        #expect(preview.rotation == .rotate0)
    }

    @Test
    func `Rotation.init from arbitrary angles normalizes to closest of four`() {
        #expect(PRMPreviewView.Rotation(angle: 0) == .rotate0)
        #expect(PRMPreviewView.Rotation(angle: 90) == .rotate90)
        #expect(PRMPreviewView.Rotation(angle: -90) == .rotate270)
        #expect(PRMPreviewView.Rotation(angle: 450) == .rotate90)
        #expect(PRMPreviewView.Rotation(angle: 45) == .rotate0) // unsupported angle falls back
    }

    @Test
    func `update() is callable from nonisolated context`() {
        let preview = PRMPreviewView()
        // Create a tiny pixel buffer purely to verify update doesn't crash.
        let attrs: NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        if let pixelBuffer { preview.update(pixelBuffer) }
    }

    @Test
    func `Texture mapping matches the drawn quad for every rotation`() {
        let unit = CGSize(width: 1, height: 1)
        // View top-left (0, 0) shows these texture corners, per the quad's tables.
        let expectations: [(PRMPreviewView.Rotation, CGPoint)] = [
            (.rotate0, CGPoint(x: 0, y: 0)),
            (.rotate90, CGPoint(x: 0, y: 1)),
            (.rotate180, CGPoint(x: 1, y: 1)),
            (.rotate270, CGPoint(x: 1, y: 0)),
        ]
        for (rotation, expected) in expectations {
            let mapped = PRMPreviewView.texturePoint(
                fromNormalizedViewPoint: .zero,
                rotation: rotation,
                mirroring: false,
                contentScale: unit
            )
            #expect(abs(mapped.x - expected.x) < 1e-9 && abs(mapped.y - expected.y) < 1e-9, "\(rotation)")
        }
    }

    @Test
    func `Fill crop and letterbox are undone`() {
        // `.fill` overflowing 2× horizontally: the view's left edge is a quarter in.
        let fill = PRMPreviewView.texturePoint(
            fromNormalizedViewPoint: CGPoint(x: 0, y: 0.5),
            rotation: .rotate0,
            mirroring: false,
            contentScale: CGSize(width: 2, height: 1)
        )
        #expect(abs(fill.x - 0.25) < 1e-9)
        // `.fit` at half height: a tap in the top letterbox lands above the texture.
        let fit = PRMPreviewView.texturePoint(
            fromNormalizedViewPoint: CGPoint(x: 0.5, y: 0.1),
            rotation: .rotate0,
            mirroring: false,
            contentScale: CGSize(width: 1, height: 0.5)
        )
        #expect(fit.y < 0)
    }

    @Test
    func `View and texture mappings are inverses`() {
        let scale = CGSize(width: 1.6, height: 1)
        let point = CGPoint(x: 0.3, y: 0.8)
        for rotation in [PRMPreviewView.Rotation.rotate0, .rotate90, .rotate180, .rotate270] {
            for mirroring in [false, true] {
                let texture = PRMPreviewView.texturePoint(fromNormalizedViewPoint: point, rotation: rotation, mirroring: mirroring, contentScale: scale)
                let back = PRMPreviewView.normalizedViewPoint(fromTexturePoint: texture, rotation: rotation, mirroring: mirroring, contentScale: scale)
                #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9, "\(rotation) mirrored=\(mirroring)")
            }
        }
    }
}
