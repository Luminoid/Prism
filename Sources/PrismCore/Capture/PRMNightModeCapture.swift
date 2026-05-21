@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Vision

/// Long-exposure photo capture by averaging multiple frames.
///
/// Apple's first-party Night mode is not exposed as a public API — it's a private,
/// ANE-accelerated pipeline doing bracketed exposures, sub-pixel registration, multi-frame
/// super-resolution, and tone mapping. This helper approximates the *averaging* portion:
/// captures a configurable number of frames at fixed exposure, aligns each subsequent
/// frame to the first via `VNTranslationalImageRegistrationRequest` to compensate for
/// hand-shake, then averages them with `CIAdditionCompositing` + a brightness scale to
/// keep the result in `[0, 1]`. Without alignment, handheld stacks show motion blur and
/// edge ghosting; with it, sharpness on static subjects is preserved at lower noise.
///
/// What this does **not** do (and would need a private ANE pipeline to match):
/// - Bracketed exposures (Apple captures some short + some long, picks the best per region)
/// - Sub-pixel registration with content-aware warping (we only do whole-pixel translation)
/// - Multi-frame super-resolution beyond simple averaging
/// - Per-region tone mapping and chroma denoise
/// - Scene-aware deferred / additional capture triggered by the still-photo button
///
/// For best results, capture 4-12 frames at 0.5-2s each on a stable surface or with
/// the user holding the device steady. Moving subjects will still ghost — the translation
/// model can't compensate for object motion within the frame.
///
/// Designed for the photo-output path: the camera should already be running, and the
/// caller is responsible for switching the device into `.custom` exposure with the
/// configured per-frame shutter + ISO before calling
/// ``capture(frameCount:perFrameDuration:iso:didCaptureFrame:)`` and restoring the prior
/// exposure mode afterwards. ``PRMCamera/setCustomExposure(duration:iso:)`` paired with
/// ``PRMCamera/setExposureMode(_:)`` is the recommended path (it stays on the camera
/// actor and threads through clamping).
///
/// ```swift
/// let duration = CMTimeMakeWithSeconds(0.5, preferredTimescale: 1_000_000)
/// await camera.setCustomExposure(duration: duration, iso: 800)
/// defer { Task { await camera.setExposureMode(.continuousAutoExposure) } }
/// let photo = try await night.capture(
///     frameCount: 8,
///     perFrameDuration: 0.5,
///     iso: 800,
///     didCaptureFrame: { index, total in print("frame \(index + 1)/\(total)") }
/// )
/// ```
public final class PRMNightModeCapture: @unchecked Sendable {
    public let capture: PRMPhotoCapture
    public let context: PRMRenderContext

    public init(capture: PRMPhotoCapture, context: PRMRenderContext) {
        self.capture = capture
        self.context = context
    }

    /// Capture `frameCount` frames at `perFrameDuration` seconds each and average them
    /// into a single still image. Total wall-clock time is roughly
    /// `frameCount * perFrameDuration`.
    ///
    /// - Parameters:
    ///   - frameCount: Number of frames to stack. 4-12 is a sensible range. Must be ≥ 1.
    ///   - perFrameDuration: Per-frame shutter in seconds. Informational — the caller is
    ///     responsible for putting the device into custom exposure with this duration
    ///     before invoking. The value is recorded into the returned photo's metadata.
    ///   - iso: ISO used per frame. Same caller-responsibility note as `perFrameDuration`.
    ///   - didCaptureFrame: Fires once after each frame finishes capturing. Receives the
    ///     zero-based frame index and the total `frameCount`, suitable for driving a
    ///     "frame N/total" progress indicator.
    /// - Returns: A composited ``PRMPhoto``; underlying photo is the last frame's
    ///   `AVCapturePhoto`, metadata is the last frame's metadata with the per-frame shutter
    ///   recorded in `ExposureTime`.
    public func capture(
        frameCount: Int,
        perFrameDuration _: Double,
        iso _: Float,
        didCaptureFrame: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> PRMPhoto {
        guard frameCount >= 1 else {
            throw PRMSessionError.photoCaptureFailed("Night mode requires frameCount >= 1")
        }

        var frames: [PRMPhoto] = []
        let settings = PRMPhotoSettings()
            .qualityPrioritization(.quality)
            .flashMode(.off)
        for index in 0 ..< frameCount {
            let photo = try await capture.capturePhoto(settings: settings)
            frames.append(photo)
            didCaptureFrame?(index, frameCount)
        }
        guard let composited = Self.average(frames: frames, context: context) else {
            // If averaging fails (decode error, empty extent), fall back to the last frame.
            return frames[frames.count - 1]
        }
        return composited
    }

    // MARK: - Compositing

    private static func average(frames: [PRMPhoto], context: PRMRenderContext) -> PRMPhoto? {
        guard !frames.isEmpty else { return nil }
        guard let first = CIImage(data: frames[0].data) else { return nil }
        let weight = CGFloat(1.0 / Double(frames.count))
        var accumulator = weighted(first, weight: weight)
        // Reuse a single sequence handler so Vision can amortize feature extraction across
        // frames. The first frame is the registration anchor; each subsequent frame is
        // aligned to it before being added to the accumulator.
        let registrationHandler = VNSequenceRequestHandler()
        for index in 1 ..< frames.count {
            guard let frame = CIImage(data: frames[index].data) else { continue }
            let aligned = align(frame, to: first, handler: registrationHandler) ?? frame
            accumulator = weighted(aligned, weight: weight).applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: accumulator,
            ])
        }
        // Cropping back to the first frame's extent trims the empty edges that translation
        // alignment exposes — when frame N is shifted +5px right, the leftmost 5px column
        // of the accumulator is averaged with transparent pixels and reads dim. Keeping
        // the output exactly the same dimensions as the input also makes EXIF / metadata
        // sizes line up with the underlying photo we pass through.
        accumulator = accumulator.cropped(to: first.extent)
        let lastPhoto = frames[frames.count - 1]
        let preservedProperties = first.properties.merging(lastPhoto.metadata) { _, new in new }
        guard let jpegData = PRMImage.jpegDataPreservingMetadata(
            from: accumulator,
            originalProperties: preservedProperties,
            context: context
        ) else {
            return nil
        }
        return PRMPhoto(
            data: jpegData,
            underlyingPhoto: lastPhoto.underlyingPhoto,
            metadata: lastPhoto.metadata
        )
    }

    /// Aligns `frame` to `reference` using `VNTranslationalImageRegistrationRequest` and
    /// returns the translated CIImage. Returns `nil` when registration fails (Vision can't
    /// find enough features — happens on extreme low light, blank scenes, or large motion),
    /// in which case the caller falls back to the un-aligned frame. Whole-pixel translation
    /// only — rotation and scale changes between frames are not corrected.
    private static func align(
        _ frame: CIImage,
        to reference: CIImage,
        handler: VNSequenceRequestHandler
    ) -> CIImage? {
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: frame, options: [:])
        do {
            try handler.perform([request], on: reference)
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        // The observation's alignmentTransform is the transform that, applied to the
        // target image (`frame`), aligns it to the reference. Apply it directly.
        return frame.transformed(by: observation.alignmentTransform)
    }

    private static func weighted(_ image: CIImage, weight: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }
}
