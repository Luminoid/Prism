@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO

// MARK: - Encoding

//
// What happens to a delivered `AVCapturePhoto` before the caller gets it: the manual-exposure
// EXIF patch, the optional filter pass, and the outcome log line. Runs on AVFoundation's
// delegate queue, outside `PRMPhotoCapture.lock`.

extension PRMPhotoCapture {
    /// The photo's file data, with EXIF `ExposureTime` / `ISOSpeedRatings` /
    /// `ShutterSpeedValue` patched to the manual values when given (AVFoundation writes the
    /// auto-AE values into a bracket capture's EXIF on iPhone 14 Pro+, Apple dev-forum
    /// 120427). Falls back to the unpatched data when the patch is declined.
    static func fileData(of photo: AVCapturePhoto, manualISO: Float?, manualDuration: CMTime?) -> Data? {
        guard let manualISO, let manualDuration, manualDuration.isValid else {
            return photo.fileDataRepresentation()
        }
        let customizer = ExposurePatchCustomizer(iso: manualISO, exposureDuration: manualDuration)
        return photo.fileDataRepresentation(with: customizer) ?? photo.fileDataRepresentation()
    }

    /// Applies the capture's filter recipe to the original data. A recipe without a render
    /// context uses ``PRMRenderContext/shared``; when that's unavailable (no Metal) the
    /// photo is returned unfiltered with a warning.
    func renderPhoto(
        originalData: Data,
        photo: AVCapturePhoto,
        pending: PendingCapture
    ) -> PRMPhoto {
        let metadata = photo.metadata
        let finalData: Data

        switch pending.filterRecipe {
        case .none:
            finalData = originalData

        case let .single(filter, context):
            guard let context = context ?? PRMRenderContext.shared else {
                PRMLog.warning(.capture, "No render context for the filter pass; the photo is unfiltered")
                finalData = originalData
                break
            }
            guard let sourceImage = CIImage(data: originalData) else {
                PRMLog.warning(.capture, "Captured data didn't decode for the filter pass; the photo is unfiltered")
                finalData = originalData
                break
            }
            let filtered = filter.render(sourceImage)
            let preservedProperties = sourceImage.properties.merging(metadata) { _, new in new }
            finalData = Self.encodeFilteredImage(
                filtered,
                sourceExtent: sourceImage.extent,
                preservedProperties: preservedProperties,
                codec: pending.filterCodec,
                context: context
            ) ?? originalData

        case let .chain(entries, context):
            guard let sourceImage = CIImage(data: originalData) else {
                PRMLog.warning(.capture, "Captured data didn't decode for the filter chain; the photo is unfiltered")
                finalData = originalData
                break
            }
            // Reuse the chain's own static helper so the still-capture output matches
            // the live preview pixel-for-pixel (same intensity-blend math, same order).
            let blended = PRMFilterChain.apply(entries, to: sourceImage)
            let preservedProperties = sourceImage.properties.merging(metadata) { _, new in new }
            finalData = Self.encodeFilteredImage(
                blended,
                sourceExtent: sourceImage.extent,
                preservedProperties: preservedProperties,
                codec: pending.filterCodec,
                context: context
            ) ?? originalData
        }
        return PRMPhoto(data: finalData, underlyingPhoto: photo, metadata: metadata)
    }

    /// Route the filtered CIImage to the codec the caller asked for on `PRMPhotoSettings`.
    /// `.hevc` (or anything HEIC-family) maps to ``PRMImage/heifDataPreservingMetadata(from:sourceExtent:originalProperties:compressionQuality:context:)``;
    /// everything else falls back to JPEG so callers that don't care about codec still get
    /// usable output. Falls back to JPEG if HEIF encode returns `nil` (older sims with no
    /// HEVC encoder).
    ///
    /// `sourceExtent` is the pre-filter source CIImage's extent — required because
    /// distortion filters (Bump, Twirl, Vortex, Edges) produce infinite extents that
    /// `heifRepresentation` silently rejects (returns nil → falls back to JPEG with no
    /// caller signal). Cropping to the source frame inside the encoder restores the
    /// expected output.
    static func encodeFilteredImage(
        _ image: CIImage,
        sourceExtent: CGRect,
        preservedProperties: [String: Any],
        codec: AVVideoCodecType?,
        context: PRMRenderContext
    ) -> Data? {
        if codec == .hevc || codec == .hevcWithAlpha {
            if let heif = PRMImage.heifDataPreservingMetadata(
                from: image,
                sourceExtent: sourceExtent,
                originalProperties: preservedProperties,
                context: context
            ) {
                PRMLog.debug(.capture, "Encoded filter chain → HEIC (\(heif.count) bytes)")
                return heif
            }
            PRMLog.warning(.capture, "HEIF encode returned nil — falling back to JPEG")
        }
        return PRMImage.jpegDataPreservingMetadata(
            from: image,
            sourceExtent: sourceExtent,
            originalProperties: preservedProperties,
            context: context
        )
    }

    // MARK: - Log text

    /// `"4032x3024"`: the photo's resolved dimensions.
    static func dimensionsText(of photo: AVCapturePhoto) -> String {
        let dims = photo.resolvedSettings.photoDimensions
        return "\(dims.width)x\(dims.height)"
    }

    /// `" (asked for up to 8064x6048: <reason>)"` when the photo came back smaller than the
    /// settings asked, otherwise empty.
    static func smallerThanRequestedText(_ delivered: CMVideoDimensions, requested: CMVideoDimensions?, sizeLimit: String?) -> String {
        guard let requested,
              Int64(delivered.width) * Int64(delivered.height) < Int64(requested.width) * Int64(requested.height)
        else { return "" }
        return " (asked for up to \(requested.width)x\(requested.height): \(sizeLimit ?? "AVFoundation delivered a smaller size"))"
    }

    /// The container type of encoded photo data (`"public.heic"`, `"public.jpeg"`), read
    /// from its header without decoding.
    static func formatText(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else { return "unknown format" }
        return type as String
    }

    /// One notice line per finished capture; failures are logged where they happen. A photo
    /// smaller than `requested` says so, with `sizeLimit` as the reason when it's known.
    static func logOutcome(
        _ result: Result<PRMPhoto, any Error>,
        isLivePhoto: Bool,
        requested: CMVideoDimensions? = nil,
        sizeLimit: String? = nil
    ) {
        let kind = isLivePhoto ? "Live Photo" : "Photo"
        switch result {
        case let .success(photo):
            let proxy = photo.underlyingPhoto is AVCaptureDeferredPhotoProxy ? " (deferred proxy)" : ""
            let smaller = smallerThanRequestedText(photo.underlyingPhoto.resolvedSettings.photoDimensions, requested: requested, sizeLimit: sizeLimit)
            PRMLog.notice(
                .capture,
                "\(kind) captured: \(dimensionsText(of: photo.underlyingPhoto)) \(formatText(of: photo.data)), \(photo.data.count) bytes\(proxy)\(smaller)"
            )
        case let .failure(error):
            if error as? PRMSessionError == .cancelled {
                PRMLog.notice(.capture, "\(kind) capture cancelled")
            }
        }
    }
}

/// `AVCapturePhotoFileDataRepresentationCustomizer` that patches EXIF
/// `ExposureTime`, `ISOSpeedRatings`, and `ShutterSpeedValue` with the manual values the
/// capture fired with. AVFoundation calls `replacementMetadataForPhoto:` synchronously
/// when flattening the photo, so the customizer's lifetime only needs to span the one
/// `fileDataRepresentation(with:)` call.
private final class ExposurePatchCustomizer: NSObject,
    AVCapturePhotoFileDataRepresentationCustomizer {
    private let iso: Float
    private let exposureDuration: CMTime

    init(iso: Float, exposureDuration: CMTime) {
        self.iso = iso
        self.exposureDuration = exposureDuration
    }

    /// `@objc(replacementMetadataForPhoto:)` with the explicit ObjC selector so
    /// there's zero risk of Swift name-mangling diverging from what AVFoundation
    /// looks up via `respondsToSelector:`. The protocol method is `@optional`
    /// in the ObjC declaration — Swift doesn't auto-emit ObjC selectors for
    /// optional protocol methods unless the conforming method is marked, and
    /// even with `@objc` alone, leaving the selector implicit can produce a
    /// different stub on some toolchain versions. Hard-coding the selector is
    /// the canonical safe form.
    @objc(replacementMetadataForPhoto:)
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        var exif = (metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        let durationSeconds = CMTimeGetSeconds(exposureDuration)
        if durationSeconds > 0, durationSeconds.isFinite {
            exif[kCGImagePropertyExifExposureTime as String] = durationSeconds
            // ShutterSpeedValue is the APEX-encoded reciprocal of ExposureTime
            // (`-log2(exposureTime)`). Photo viewers display it interchangeably
            // with ExposureTime; patching both keeps third-party EXIF tools
            // consistent with Apple's Photos info pane.
            exif[kCGImagePropertyExifShutterSpeedValue as String] = -log2(durationSeconds)
        }
        if iso > 0, iso.isFinite {
            // ISOSpeedRatings is a `[CFNumberRef]` array per CGImageProperties.h.
            // Use `NSNumber` (not `Int`) so the bridge writes the EXIF tag's
            // expected SHORT (UInt16) type — `Int` bridges to NSNumber(long)
            // which some EXIF parsers misread.
            exif[kCGImagePropertyExifISOSpeedRatings as String] = [NSNumber(value: Int(iso.rounded()))]
        }
        metadata[kCGImagePropertyExifDictionary as String] = exif
        return metadata
    }
}
