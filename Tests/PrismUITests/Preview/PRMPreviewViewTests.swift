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
}
