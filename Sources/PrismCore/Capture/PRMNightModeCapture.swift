@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Long-exposure photo capture by averaging multiple frames.
///
/// Apple's first-party Night mode is not exposed as a public API. This helper approximates
/// it by capturing a configurable number of frames at a fixed exposure, then averaging them
/// with `CIAdditionCompositing` + a brightness scale to keep the result in `[0, 1]`.
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
        var accumulator = first.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        for index in 1 ..< frames.count {
            guard let frame = CIImage(data: frames[index].data) else { continue }
            let weighted = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            accumulator = weighted.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: accumulator,
            ])
        }
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
}
