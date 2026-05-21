import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Image conversion utilities that share a ``PRMRenderContext``.
///
/// Pass the same context you use for the filter pipeline so the JPEG encode happens on the
/// same Metal queue, avoiding context churn.
public enum PRMImage: Sendable {
    // MARK: - Pixel Buffer → JPEG

    /// Encodes a pixel buffer to JPEG data using the provided render context.
    public static func jpegData(
        from pixelBuffer: CVPixelBuffer,
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return jpegData(from: ciImage, compressionQuality: compressionQuality, context: context)
    }

    /// Encodes a `CIImage` to JPEG data using the provided render context.
    public static func jpegData(
        from ciImage: CIImage,
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return context.ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compressionQuality]
        )
    }

    // MARK: - Pixel Buffer → CGImage

    /// Creates a `CGImage` from a `CVPixelBuffer` using the provided render context.
    public static func cgImage(
        from pixelBuffer: CVPixelBuffer,
        context: PRMRenderContext
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return context.ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - EXIF Preservation

    /// Re-encodes a JPEG payload preserving its EXIF/TIFF dictionaries.
    ///
    /// Useful when a filter is applied to captured photo data: the filter rebuilds pixels but
    /// loses the camera's metadata; this helper writes the filtered pixels back with the
    /// original EXIF/TIFF preserved.
    public static func jpegDataPreservingMetadata(
        from filteredImage: CIImage,
        originalProperties: [String: Any],
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let colorSpace = filteredImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let options = Self.representationOptions(
            from: originalProperties,
            compressionQuality: compressionQuality
        )
        return context.ciContext.jpegRepresentation(
            of: filteredImage,
            colorSpace: colorSpace,
            options: options
        )
    }

    /// HEIF/HEIC equivalent of ``jpegDataPreservingMetadata(from:originalProperties:compressionQuality:context:)``.
    /// Used by ``PRMPhotoCapture``'s filter-encode path when the user requested an HEIC
    /// `AVVideoCodecType` on `PRMPhotoSettings`. Returns `nil` when the device's CIContext
    /// cannot encode HEIF (older simulators, missing HEVC encoder); callers should fall
    /// back to JPEG in that case.
    public static func heifDataPreservingMetadata(
        from filteredImage: CIImage,
        originalProperties: [String: Any],
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let colorSpace = filteredImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let options = Self.representationOptions(
            from: originalProperties,
            compressionQuality: compressionQuality
        )
        return context.ciContext.heifRepresentation(
            of: filteredImage,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: options
        )
    }

    private static func representationOptions(
        from originalProperties: [String: Any],
        compressionQuality: CGFloat
    ) -> [CIImageRepresentationOption: Any] {
        var options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compressionQuality,
        ]
        if let exif = originalProperties[kCGImagePropertyExifDictionary as String] {
            options[CIImageRepresentationOption(rawValue: kCGImagePropertyExifDictionary as String)] = exif
        }
        if let tiff = originalProperties[kCGImagePropertyTIFFDictionary as String] {
            options[CIImageRepresentationOption(rawValue: kCGImagePropertyTIFFDictionary as String)] = tiff
        }
        return options
    }
}
