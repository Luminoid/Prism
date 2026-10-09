import AVFoundation
import CoreMedia

/// A fluent settings builder for ``PRMPhotoCapture``.
///
/// Each method returns a new copy (value-type), so configurations can branch:
/// ```swift
/// let base = PRMPhotoSettings()
///     .flashMode(.auto)
///     .qualityPrioritization(.balanced)
///
/// let heif = base.codec(.hevc)
/// let jpeg = base
/// ```
///
/// Drops the deprecated `isAutoStillImageStabilizationEnabled` flag (iOS 13+) and adds
/// iOS 17 photo features (responsive capture / deferred / zero shutter lag are configured
/// once on the photo output via ``PRMCameraConfiguration``).
public struct PRMPhotoSettings: Sendable {
    public var flashMode: AVCaptureDevice.FlashMode = .off
    public var qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .balanced
    public var codec: AVVideoCodecType?
    public var maxDimensions: CMVideoDimensions?
    public var autoRedEyeReduction: Bool?
    public var depthDataDelivery: Bool?
    /// When true (default), embed the depth map into the photo's file representation
    /// (JPEG/HEIC sidecar). When false, the depth is delivered ONLY via
    /// `AVCapturePhoto.depthData` and not embedded in the file — required for the
    /// photo bokeh path in this package, which re-encodes the photo data without
    /// depth metadata. Some configurations (notably iPhone Pro with deferred-photo
    /// delivery on) only populate `AVCapturePhoto.depthData` when this is false.
    public var embedsDepthDataInPhoto: Bool?
    /// When true (default), embed the portrait effects matte into the photo file.
    /// AVFoundation enforces an invariant: if this is true, `embedsDepthDataInPhoto`
    /// must also be true — embedding the matte without depth throws
    /// `NSInvalidArgumentException` at capture time. Pair with `embedsDepthDataInPhoto`
    /// (both true together for embed, both false for property-only delivery).
    public var embedsPortraitEffectsMatteInPhoto: Bool?
    /// Ignored: a Live Photo is whatever ``PRMPhotoCapture/captureLivePhoto(settings:willCapture:)``
    /// captures, which supplies the movie URL itself.
    @available(*, deprecated, message: "Ignored; call PRMPhotoCapture.captureLivePhoto(settings:willCapture:) for a Live Photo")
    public var livePhoto: Bool {
        get { false }
        set { _ = newValue }
    }

    /// When true and the photo output supports it, request a portrait effects matte
    /// alongside the still image (used by depth-based bokeh).
    public var portraitEffectsMatte: Bool?

    /// User-intended ISO + exposure duration to bake into the captured
    /// photo's EXIF (ExposureTime, ISOSpeedRatings, ShutterSpeedValue). When
    /// non-nil, ``PRMPhotoCapture`` will patch the saved photo's metadata
    /// with these values via `AVCapturePhotoFileDataRepresentationCustomizer`
    /// — closing the race where `device.iso` / `device.exposureDuration`
    /// still report stale auto values at the moment the capture pipeline
    /// fires (Apple dev-forum 120427).
    ///
    /// Studio populates this from `PRMCamera.currentManualExposureSnapshot`
    /// which reflects the user's intent rather than the device's lagging
    /// reads, so even when the AVF commit hasn't fully landed yet the saved
    /// photo's EXIF still shows the slider values.
    ///
    /// The override fires as a manual-exposure bracket, which needs a camera
    /// that takes manual exposure (`AVCaptureDevice.prm_supportsManualExposureCapture`;
    /// virtual multi-camera devices don't). Without one the photo is captured
    /// at the device's own exposure, and the EXIF is patched only if the device
    /// is in `.custom`.
    public var manualExposureOverride: (iso: Float, duration: CMTime)?

    /// Rotation for the saved photo, in degrees (`videoRotationAngle` on the photo output's
    /// connection, applied just before the shutter fires). Pass
    /// ``PRMRotationCoordinator/currentCaptureRotationAngle`` so landscape shots save
    /// upright. `nil` leaves the connection as it is.
    public var rotationAngle: CGFloat?

    public init() {}

    // MARK: - Builder

    public func flashMode(_ value: AVCaptureDevice.FlashMode) -> Self {
        var copy = self
        copy.flashMode = value
        return copy
    }

    public func qualityPrioritization(_ value: AVCapturePhotoOutput.QualityPrioritization) -> Self {
        var copy = self
        copy.qualityPrioritization = value
        return copy
    }

    public func codec(_ value: AVVideoCodecType) -> Self {
        var copy = self
        copy.codec = value
        return copy
    }

    public func maxDimensions(_ value: CMVideoDimensions) -> Self {
        var copy = self
        copy.maxDimensions = value
        return copy
    }

    public func autoRedEyeReduction(_ enabled: Bool) -> Self {
        var copy = self
        copy.autoRedEyeReduction = enabled
        return copy
    }

    public func depthDataDelivery(_ enabled: Bool) -> Self {
        var copy = self
        copy.depthDataDelivery = enabled
        return copy
    }

    public func embedsDepthDataInPhoto(_ enabled: Bool) -> Self {
        var copy = self
        copy.embedsDepthDataInPhoto = enabled
        return copy
    }

    public func embedsPortraitEffectsMatteInPhoto(_ enabled: Bool) -> Self {
        var copy = self
        copy.embedsPortraitEffectsMatteInPhoto = enabled
        return copy
    }

    /// Ignored; see ``livePhoto``.
    @available(*, deprecated, message: "Ignored; call PRMPhotoCapture.captureLivePhoto(settings:willCapture:) for a Live Photo")
    public func livePhoto(_: Bool) -> Self {
        self
    }

    public func portraitEffectsMatte(_ enabled: Bool) -> Self {
        var copy = self
        copy.portraitEffectsMatte = enabled
        return copy
    }

    /// See ``manualExposureOverride``.
    public func manualExposureOverride(iso: Float, duration: CMTime) -> Self {
        var copy = self
        copy.manualExposureOverride = (iso, duration)
        return copy
    }

    /// See ``rotationAngle``.
    public func rotationAngle(_ degrees: CGFloat) -> Self {
        var copy = self
        copy.rotationAngle = degrees
        return copy
    }

    // MARK: - Materialize

    /// Builds an `AVCapturePhotoSettings` with no output to check against: unsupported
    /// codecs, quality above the output's maximum and invalid dimensions all raise at
    /// capture time.
    @available(*, deprecated, message: "Use makeAVSettings(for:), which validates against the output")
    public func makeAVSettings() -> AVCapturePhotoSettings {
        makeUncheckedAVSettings(codec: codec, quality: qualityPrioritization, maxDimensions: maxDimensions)
    }

    /// Builds `AVCapturePhotoSettings` that the given output accepts. AVFoundation raises
    /// `NSInvalidArgumentException` from `capturePhoto(with:delegate:)` for each of these, so
    /// they're corrected here instead:
    ///
    /// - A codec the output doesn't offer (the simulator has no HEVC encoder; some older
    ///   devices list `[.jpeg]` only) falls back to the default (JPEG).
    /// - Quality prioritization above the output's `maxPhotoQualityPrioritization` is lowered
    ///   to it.
    /// - `maxDimensions` must be one of the active format's `supportedMaxPhotoDimensions` and
    ///   no larger than the output's ceiling; otherwise the largest valid entry that fits is
    ///   used (or none). A notice is logged when it changes.
    public func makeAVSettings(for output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
        let effectiveCodec = Self.availableCodec(codec, on: output)
        let quality = Self.clampedQuality(qualityPrioritization, max: output.maxPhotoQualityPrioritization)
        let dimensions = maxDimensions.flatMap { requested in
            Self.validatedMaxDimensions(
                requested,
                supported: output.prm_sourceDevice?.activeFormat.supportedMaxPhotoDimensions ?? [],
                ceiling: output.maxPhotoDimensions
            )
        }
        if let requested = maxDimensions, dimensions?.width != requested.width || dimensions?.height != requested.height {
            let applied = dimensions.map { "\($0.width)×\($0.height)" } ?? "the output default"
            PRMLog.notice(.capture, "Photo maxDimensions \(requested.width)×\(requested.height) isn't available; using \(applied)")
        }
        return makeUncheckedAVSettings(codec: effectiveCodec, quality: quality, maxDimensions: dimensions)
    }

    /// `codec` when `output` offers it. Otherwise `nil` (AVFoundation's default, JPEG where
    /// HEVC isn't offered), with a notice naming what the output offers: the photo comes back
    /// in another format without an error.
    static func availableCodec(_ codec: AVVideoCodecType?, on output: AVCapturePhotoOutput) -> AVVideoCodecType? {
        guard let codec else { return nil }
        let offered = output.availablePhotoCodecTypes
        guard !offered.contains(codec) else { return codec }
        let offeredText = offered.isEmpty ? "none" : offered.map(\.rawValue).joined(separator: ", ")
        PRMLog.notice(.capture, "Photo codec \(codec.rawValue) isn't offered by the output now (it offers \(offeredText)); using the default")
        return nil
    }

    private func makeUncheckedAVSettings(
        codec effectiveCodec: AVVideoCodecType?,
        quality: AVCapturePhotoOutput.QualityPrioritization,
        maxDimensions dimensions: CMVideoDimensions?
    ) -> AVCapturePhotoSettings {
        let settings = if let effectiveCodec {
            AVCapturePhotoSettings(format: [AVVideoCodecKey: effectiveCodec])
        } else {
            AVCapturePhotoSettings()
        }
        settings.flashMode = flashMode
        settings.photoQualityPrioritization = quality
        if let dimensions {
            settings.maxPhotoDimensions = dimensions
        }
        if let autoRedEyeReduction {
            settings.isAutoRedEyeReductionEnabled = autoRedEyeReduction
        }
        if let depthDataDelivery {
            settings.isDepthDataDeliveryEnabled = depthDataDelivery
        }
        if let embedsDepthDataInPhoto {
            settings.embedsDepthDataInPhoto = embedsDepthDataInPhoto
        }
        if let portraitEffectsMatte {
            settings.isPortraitEffectsMatteDeliveryEnabled = portraitEffectsMatte
        }
        if let embedsPortraitEffectsMatteInPhoto {
            settings.embedsPortraitEffectsMatteInPhoto = embedsPortraitEffectsMatteInPhoto
        }
        return settings
    }

    // MARK: - Validation helpers

    /// `requested`, lowered to `maximum` when it's higher.
    static func clampedQuality(
        _ requested: AVCapturePhotoOutput.QualityPrioritization,
        max maximum: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        requested.rawValue > maximum.rawValue ? maximum : requested
    }

    /// The dimensions to request: `requested` when it's one of `supported` and fits the
    /// output's `ceiling`; otherwise the largest supported entry that fits both (by area), or
    /// `nil` when none does. A zero `ceiling` (output still rebuilding) only checks
    /// `supported`. Pure, so it's unit-testable.
    static func validatedMaxDimensions(
        _ requested: CMVideoDimensions,
        supported: [CMVideoDimensions],
        ceiling: CMVideoDimensions
    ) -> CMVideoDimensions? {
        let hasCeiling = ceiling.width > 0 && ceiling.height > 0
        func fits(_ dims: CMVideoDimensions, within bound: CMVideoDimensions) -> Bool {
            dims.width <= bound.width && dims.height <= bound.height
        }
        let candidates = supported.filter { !hasCeiling || fits($0, within: ceiling) }
        if candidates.contains(where: { $0.width == requested.width && $0.height == requested.height }) {
            return requested
        }
        return candidates
            .filter { fits($0, within: requested) }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
}
