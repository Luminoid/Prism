@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import os
import QuartzCore

/// Night mode: gathers light from many frames of the live video stream for a few seconds,
/// aligns and merges them on the GPU, then brightens and tone-maps the result.
///
/// Apple's own Night mode isn't public API. This one works the same way in outline:
///
/// 1. **Plan** (``plan(_:)``): from how far auto exposure falls short of its target in the
///    dark, a per-frame shutter (about 1/8 s handheld on the main lens, up to 1/2 s when
///    stable) and ISO, and a capture time of 1 to 3 s handheld (up to 10 s stable).
/// 2. **Capture:** the camera is held at that exposure with white balance and focus locked,
///    and frames come from the video-data output while the preview keeps running. Other
///    camera controls are refused meanwhile (``PRMCameraSession/isExclusiveCaptureActive``).
/// 3. **Merge:** each frame is aligned to the first with Vision (a homography, so hand
///    rotation is corrected too), frames blurred by shake are dropped, and pixels that differ
///    from the first frame by more than noise (something moved) are left out. The weighted
///    average cuts noise by about the square root of the frame count.
/// 4. **Tone:** the merge is brightened by up to 3 EV toward a dusk-like level, highlights are
///    rolled off with a shoulder, and the remaining noise is smoothed.
///
/// The photo has the video-data output's resolution (the format's full size: under the
/// `.photo` preset the capture moves to `.inputPriority` if the stream comes smaller) and the
/// photo connection's rotation and mirroring. Manual exposure needs a physical camera: on a
/// virtual multi-camera device (the Triple or Dual camera Pro iPhones open by default) switch
/// to `.builtInWideAngleCamera` first, or the capture throws.
///
/// ```swift
/// let night = PRMNightModeCapture(session: camera.session, context: renderContext)
/// let photo = try await night.capture(PRMNightModeOptions(rotationAngle: angle)) { progress in
///     Task { @MainActor in pill.text = "\(progress.secondsRemaining)s" }
/// }
/// ```
public final class PRMNightModeCapture: @unchecked Sendable {
    public let session: PRMCameraSession
    /// The context the merge and encode run on: a separate command queue on the caller's
    /// device, so the work doesn't stall a preview drawing with the caller's context.
    private let context: PRMRenderContext

    public init(session: PRMCameraSession, context: PRMRenderContext) {
        self.session = session
        let queue = context.device.makeCommandQueue() ?? context.commandQueue
        self.context = PRMRenderContext(device: context.device, commandQueue: queue, name: "PRMNightModeCapture")
    }

    /// The plan a capture would use right now (for an "AUTO 3s" label), or `nil` without a
    /// camera.
    public func plan(_ options: PRMNightModeOptions = PRMNightModeOptions()) async -> PRMNightPlan? {
        await session.nightPlan(options: options)
    }

    /// Captures a Night photo.
    ///
    /// `progress` is called about 20 times a second while capturing (on no particular
    /// thread), then once with ``PRMNightProgress/Phase/processing`` when the camera is back
    /// to normal and merging finishes.
    ///
    /// - Throws: Before anything changes:
    ///   ``PRMSessionError/virtualDeviceManualControlUnsupported(_:)`` on a virtual
    ///   multi-camera device, ``PRMSessionError/unsupportedConfiguration(_:)`` while recording
    ///   or with Cinematic Video or Live Photo on. During the capture:
    ///   ``PRMSessionError/cancelled`` when the task is cancelled, and
    ///   ``PRMSessionError/photoCaptureFailed(_:)`` when no usable frame arrived or encoding
    ///   failed. The camera is restored in every case.
    public func capture(
        _ options: PRMNightModeOptions = PRMNightModeOptions(),
        progress: (@Sendable (PRMNightProgress) -> Void)? = nil
    ) async throws -> PRMNightPhoto {
        let frameDimensions = await probeFrameDimensions()
        if let frameDimensions, !Self.hasMemory(forWidth: Int(frameDimensions.width), height: Int(frameDimensions.height)) {
            throw PRMSessionError.photoCaptureFailed("Not enough memory for a Night capture")
        }
        let lease = try await session.beginNightCapture(options: options, frameDimensions: frameDimensions)
        let plan = lease.plan
        let stacker = PRMNightStacker(plan: plan, context: context)
        var observer: UUID?
        do {
            try await session.applyNightExposure(lease)
            stacker.setSettleDeadline(CACurrentMediaTime() + 2 * plan.frameDuration + 0.1)
            observer = session.frameRouter.addObserver { [stacker] sampleBuffer in
                stacker.offer(sampleBuffer)
            }
            try await gather(into: stacker, plan: plan, progress: progress)
        } catch {
            await stop(stacker, observer: observer, lease: lease)
            throw error is CancellationError ? PRMSessionError.cancelled : error
        }
        await stop(stacker, observer: observer, lease: lease)

        let status = stacker.currentStatus
        progress?(PRMNightProgress(phase: .processing, elapsed: plan.duration, duration: plan.duration, mergedFrames: status.merged, plannedFrames: plan.frameCount))
        return try await finish(
            stacker,
            plan: plan,
            rotation: (options.rotationAngle ?? lease.photoRotation) - lease.dataRotation,
            mirrored: lease.photoMirrored != lease.dataMirrored,
            codec: options.codec
        )
    }

    // MARK: - Capture

    /// Waits until the plan's frames are merged or its time is up, reporting progress. Stops
    /// early when frames stop arriving (an interruption).
    private func gather(into stacker: PRMNightStacker, plan: PRMNightPlan, progress: (@Sendable (PRMNightProgress) -> Void)?) async throws {
        let start = CACurrentMediaTime()
        let stall = 2 * plan.frameDuration + 1.5
        while true {
            try Task.checkCancellation()
            let status = stacker.currentStatus
            let now = CACurrentMediaTime()
            let elapsed = now - start
            progress?(PRMNightProgress(
                phase: .capturing,
                elapsed: min(elapsed, plan.duration),
                duration: plan.duration,
                mergedFrames: status.merged,
                plannedFrames: plan.frameCount
            ))
            if status.merged >= plan.frameCount { return }
            if elapsed >= plan.duration, status.merged > 0 { return }
            if now - (status.lastAcceptedTime ?? start) > stall + (status.merged == 0 ? 1 : 0) {
                PRMLog.warning(.capture, "Night: frames stopped after \(status.merged) of \(plan.frameCount)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func stop(_ stacker: PRMNightStacker, observer: UUID?, lease: PRMNightCaptureLease) async {
        if let observer {
            session.frameRouter.removeObserver(observer)
        }
        stacker.stopAccepting()
        await session.endNightCapture(lease)
    }

    /// The video-data output's frame size, read from the next frame (at most one second).
    private func probeFrameDimensions() async -> CMVideoDimensions? {
        let found = OSAllocatedUnfairLock<CMVideoDimensions?>(initialState: nil)
        let observer = session.frameRouter.addObserver { sampleBuffer in
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            found.withLock { value in
                if value == nil { value = dimensions }
            }
        }
        defer { session.frameRouter.removeObserver(observer) }
        for _ in 0 ..< 50 {
            if let dimensions = found.withLock({ $0 }) {
                return dimensions
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Room for the merge: the accumulator and the result (8 bytes a pixel each) plus about
    /// three half-float intermediates while tone mapping. `os_proc_available_memory()` reads 0
    /// where it isn't tracked (the simulator); that passes.
    static func hasMemory(forWidth width: Int, height: Int) -> Bool {
        let available = os_proc_available_memory()
        guard available > 0 else { return true }
        return available > width * height * 8 * 5
    }

    // MARK: - Finish

    @concurrent
    private func finish(
        _ stacker: PRMNightStacker,
        plan: PRMNightPlan,
        rotation: CGFloat,
        mirrored: Bool,
        codec: AVVideoCodecType?
    ) async throws -> PRMNightPhoto {
        await stacker.drain()
        let status = stacker.currentStatus
        let mergedCount = status.merged
        guard let (merged, attachments) = stacker.finish() else {
            throw PRMSessionError.photoCaptureFailed("Night capture got no usable frames")
        }
        let linear = CIImage(cvPixelBuffer: merged, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any])
        let stats = PRMNightTone.stats(luminances: PRMNightTone.luminanceSamples(of: linear, context: context.ciContext))
        let gain = PRMNightTone.gainEV(key: stats.logAverage, frameCount: mergedCount)
        let toned = PRMNightTone.render(linear, gainEV: gain, highlight: stats.highlight, frameCount: mergedCount)
        let upright = PRMNightTone.oriented(toned, clockwiseDegrees: rotation, mirrored: mirrored)
        let date = Date()
        let metadata = Self.metadata(attachments: attachments, plan: plan, mergedFrames: mergedCount, date: date)
        guard let data = PRMPhotoCapture.encodeFilteredImage(
            upright,
            sourceExtent: upright.extent,
            preservedProperties: metadata,
            codec: codec,
            context: context
        ) else {
            throw PRMSessionError.photoCaptureFailed("Night photo couldn't be encoded")
        }
        PRMLog.notice(
            .capture,
            """
            Night photo: \(mergedCount) of \(plan.frameCount) frames (\(status.rejected) rejected, \(status.skipped) skipped while merging), \
            key \(String(format: "%.3f", stats.logAverage)), \
            gain +\(String(format: "%.1f", gain)) EV, \(Int(upright.extent.width))×\(Int(upright.extent.height)), \(data.count) bytes
            """
        )
        return PRMNightPhoto(data: data, metadata: metadata, plan: plan, mergedFrameCount: mergedCount, gainEV: gain, timestamp: date)
    }

    // MARK: - Metadata

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// The EXIF and TIFF dictionaries for the photo: the reference frame's camera metadata
    /// (lens, aperture, brightness) with the per-frame shutter and ISO, the capture time, and a
    /// note of how many frames went in. The pixels are upright, so the orientation is 1.
    static func metadata(attachments: [String: Any]?, plan: PRMNightPlan, mergedFrames: Int, date: Date) -> [String: Any] {
        var exif = (attachments?[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifExposureTime as String] = plan.frameDuration
        exif[kCGImagePropertyExifShutterSpeedValue as String] = -log2(plan.frameDuration)
        exif[kCGImagePropertyExifISOSpeedRatings as String] = [NSNumber(value: Int(plan.iso.rounded()))]
        exif[kCGImagePropertyExifUserComment as String] = "Night mode: \(mergedFrames) frames over \(String(format: "%.1f", plan.duration)) s"
        exif[kCGImagePropertyExifDateTimeOriginal as String] = exifDateFormatter.string(from: date)
        exif[kCGImagePropertyExifDateTimeDigitized as String] = exifDateFormatter.string(from: date)
        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
        exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
        var tiff = (attachments?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = "Prism Night mode"
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        return [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
        ]
    }
}
