import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Image conversion utilities for the camera pipeline.
public enum PRMImageHelper: Sendable {
    // MARK: - Pixel Buffer → JPEG

    /// Converts a `CVPixelBuffer` to JPEG `Data`.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source pixel buffer (typically 32BGRA from the camera pipeline).
    ///   - compressionQuality: JPEG compression quality, `0.0` (max compression) to `1.0` (best quality). Defaults to `0.9`.
    /// - Returns: JPEG data, or `nil` if conversion fails.
    public static func jpegData(
        from pixelBuffer: CVPixelBuffer,
        compressionQuality: CGFloat = 0.9,
    ) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return jpegData(from: ciImage, compressionQuality: compressionQuality)
    }

    /// Converts a `CIImage` to JPEG `Data`.
    ///
    /// - Parameters:
    ///   - ciImage: The source image.
    ///   - compressionQuality: JPEG compression quality, `0.0` to `1.0`. Defaults to `0.9`.
    /// - Returns: JPEG data, or `nil` if conversion fails.
    public static func jpegData(
        from ciImage: CIImage,
        compressionQuality: CGFloat = 0.9,
    ) -> Data? {
        let context = CIContext()
        let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compressionQuality],
        )
    }

    // MARK: - Pixel Buffer → CGImage

    /// Creates a `CGImage` from a `CVPixelBuffer`.
    ///
    /// - Parameter pixelBuffer: The source pixel buffer.
    /// - Returns: A `CGImage`, or `nil` if conversion fails.
    public static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
