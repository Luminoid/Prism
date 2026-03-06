import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import PrismCore

// MARK: - PRMImageHelperTests

@Suite("PRMImageHelper")
struct PRMImageHelperTests {
    // MARK: - Helpers

    /// Creates a 2×2 32BGRA pixel buffer for testing.
    private func makeTestPixelBuffer(width: Int = 2, height: Int = 2) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer,
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    // MARK: - JPEG from Pixel Buffer

    @Test("JPEG data from pixel buffer returns non-nil")
    func jpegFromPixelBuffer() throws {
        let buffer = try #require(makeTestPixelBuffer())
        let data = PRMImageHelper.jpegData(from: buffer)
        #expect(data != nil)
    }

    @Test("JPEG data from pixel buffer is valid JPEG")
    func jpegIsValid() throws {
        let buffer = try #require(makeTestPixelBuffer())
        let data = try #require(PRMImageHelper.jpegData(from: buffer))
        // JPEG files start with FF D8 FF
        #expect(data.count >= 3)
        #expect(data[0] == 0xFF)
        #expect(data[1] == 0xD8)
        #expect(data[2] == 0xFF)
    }

    @Test("JPEG compression quality affects file size")
    func compressionQualityAffectsSize() throws {
        let buffer = try #require(makeTestPixelBuffer(width: 64, height: 64))
        let highQuality = try #require(PRMImageHelper.jpegData(from: buffer, compressionQuality: 1.0))
        let lowQuality = try #require(PRMImageHelper.jpegData(from: buffer, compressionQuality: 0.1))
        #expect(highQuality.count >= lowQuality.count)
    }

    // MARK: - JPEG from CIImage

    @Test("JPEG data from CIImage returns non-nil")
    func jpegFromCIImage() {
        let ciImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = PRMImageHelper.jpegData(from: ciImage)
        #expect(data != nil)
    }

    // MARK: - CGImage from Pixel Buffer

    @Test("CGImage from pixel buffer returns non-nil")
    func cgImageFromPixelBuffer() throws {
        let buffer = try #require(makeTestPixelBuffer())
        let cgImage = PRMImageHelper.cgImage(from: buffer)
        #expect(cgImage != nil)
    }

    @Test("CGImage dimensions match pixel buffer")
    func cgImageDimensions() throws {
        let buffer = try #require(makeTestPixelBuffer(width: 8, height: 4))
        let cgImage = try #require(PRMImageHelper.cgImage(from: buffer))
        #expect(cgImage.width == 8)
        #expect(cgImage.height == 4)
    }
}
