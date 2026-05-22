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
    ///
    /// `sourceExtent` is the source CIImage's `extent` before any filtering — Bump /
    /// Twirl / Vortex / Edges produce infinite extents that JPEG encode silently rejects
    /// for the same finite-extent reason HEIF does. Cropping back to the source frame
    /// produces the expected output.
    public static func jpegDataPreservingMetadata(
        from filteredImage: CIImage,
        sourceExtent: CGRect,
        originalProperties: [String: Any],
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let crop = sourceExtent.isEmpty || sourceExtent.isInfinite
            ? filteredImage.extent
            : sourceExtent
        let finite = filteredImage.cropped(to: crop)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options = Self.representationOptions(
            from: originalProperties,
            compressionQuality: compressionQuality
        )
        return context.ciContext.jpegRepresentation(
            of: finite,
            colorSpace: colorSpace,
            options: options
        )
    }

    /// HEIF/HEIC equivalent of ``jpegDataPreservingMetadata(from:originalProperties:compressionQuality:context:)``.
    /// Used by ``PRMPhotoCapture``'s filter-encode path when the user requested an HEIC
    /// `AVVideoCodecType` on `PRMPhotoSettings`. Returns `nil` when the device's CIContext
    /// cannot encode HEIF (older simulators, missing HEVC encoder); callers should fall
    /// back to JPEG in that case.
    ///
    /// Two constraints in `CIContext.heifRepresentation` that bite filter chains:
    /// (1) the image must have a **finite non-empty extent** — Bump / Twirl / Vortex /
    /// Edges / clamped-to-extent helpers all produce *infinite* extents that silently
    /// make HEIF encode return `nil`; (2) the `CGColorSpace` must be
    /// `kCGColorSpaceModelRGB` and must **match the specified format** — extended-range
    /// (P3-extended, ITU-R-2100-HLG) color spaces inherited from the original capture
    /// don't match `.RGBA8` and also fail silently. The original implementation handed
    /// off both — `filteredImage` unmodified, `colorSpace ?? deviceRGB` — and HEIF
    /// returned `nil` on every chain that contained a distortion filter, falling back to
    /// JPEG with no signal to the caller.
    ///
    /// Crop the image to a source-derived finite extent before encode, and force sRGB
    /// (which Apple guarantees matches `.RGBA8` on iPhone). `sourceExtent` is the
    /// pre-filter `CIImage(data: original).extent` — pass it explicitly so distortion
    /// filters' infinite extents collapse to the original frame.
    public static func heifDataPreservingMetadata(
        from filteredImage: CIImage,
        sourceExtent: CGRect,
        originalProperties: [String: Any],
        compressionQuality: CGFloat = 0.9,
        context: PRMRenderContext
    ) -> Data? {
        let crop = sourceExtent.isEmpty || sourceExtent.isInfinite
            ? filteredImage.extent
            : sourceExtent
        let finite = filteredImage.cropped(to: crop)
        guard !finite.extent.isEmpty, !finite.extent.isInfinite else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options = Self.representationOptions(
            from: originalProperties,
            compressionQuality: compressionQuality
        )
        return context.ciContext.heifRepresentation(
            of: finite,
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
