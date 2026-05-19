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
        return settings
    }
}
