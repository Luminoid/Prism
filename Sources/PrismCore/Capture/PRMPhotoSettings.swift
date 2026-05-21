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
    /// When true, request a paired Live Photo movie alongside the still image.
    /// Requires `enableLivePhoto` on ``PRMCameraConfiguration``. The movie sidecar URL is
    /// supplied automatically by ``PRMPhotoCapture/captureLivePhoto(settings:willCapture:)``.
    public var livePhoto: Bool = false
    /// When true and the photo output supports it, request a portrait effects matte
    /// alongside the still image (used by depth-based bokeh).
    public var portraitEffectsMatte: Bool?

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

    public func livePhoto(_ enabled: Bool) -> Self {
        var copy = self
        copy.livePhoto = enabled
        return copy
    }

    public func portraitEffectsMatte(_ enabled: Bool) -> Self {
        var copy = self
        copy.portraitEffectsMatte = enabled
        return copy
    }

    // MARK: - Materialize

    /// Builds an `AVCapturePhotoSettings` instance from this configuration.
    public func makeAVSettings() -> AVCapturePhotoSettings {
        let settings = if let codec {
            AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        } else {
            AVCapturePhotoSettings()
        }
        settings.flashMode = flashMode
        settings.photoQualityPrioritization = qualityPrioritization
        if let maxDimensions {
            settings.maxPhotoDimensions = maxDimensions
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
}
