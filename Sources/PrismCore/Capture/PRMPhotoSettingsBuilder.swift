import AVFoundation
import CoreMedia

/// Fluent builder for constructing `AVCapturePhotoSettings` with a chainable API.
///
/// Each method returns a new copy (value type) so you can branch configurations:
/// ```swift
/// let base = PRMPhotoSettingsBuilder()
///     .flashMode(.auto)
///     .qualityPrioritization(.balanced)
///
/// let heifSettings = base.photoCodecType(.hevc).build()
/// let jpegSettings = base.build()  // default JPEG
/// ```
public struct PRMPhotoSettingsBuilder: Sendable {
    // MARK: - Stored Configuration

    private var flashMode: AVCaptureDevice.FlashMode?
    private var qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization?
    private var codecType: AVVideoCodecType?
    private var maxDimensions: CMVideoDimensions?
    private var autoRedEyeReduction: Bool?
    private var depthDataDelivery: Bool?
    private var autoStillImageStabilization: Bool?

    // MARK: - Initialization

    /// Creates an empty photo settings builder with no overrides.
    public init() {}

    // MARK: - Builder Methods

    /// Sets the flash mode (`.on`, `.off`, `.auto`).
    public func flashMode(_ mode: AVCaptureDevice.FlashMode) -> Self {
        var copy = self
        copy.flashMode = mode
        return copy
    }

    /// Sets the quality prioritization (`.speed`, `.balanced`, `.quality`).
    public func qualityPrioritization(_ priority: AVCapturePhotoOutput.QualityPrioritization) -> Self {
        var copy = self
        copy.qualityPrioritization = priority
        return copy
    }

    /// Sets the photo codec type (e.g., `.hevc`, `.jpeg`).
    public func photoCodecType(_ codec: AVVideoCodecType) -> Self {
        var copy = self
        copy.codecType = codec
        return copy
    }

    /// Sets the maximum photo dimensions.
    public func maxPhotoDimensions(_ dimensions: CMVideoDimensions) -> Self {
        var copy = self
        copy.maxDimensions = dimensions
        return copy
    }

    /// Enables or disables automatic red-eye reduction.
    public func enableAutoRedEyeReduction(_ enabled: Bool) -> Self {
        var copy = self
        copy.autoRedEyeReduction = enabled
        return copy
    }

    /// Enables or disables depth data delivery.
    public func enableDepthDataDelivery(_ enabled: Bool) -> Self {
        var copy = self
        copy.depthDataDelivery = enabled
        return copy
    }

    /// Enables or disables automatic still image stabilization.
    public func enableAutoStillImageStabilization(_ enabled: Bool) -> Self {
        var copy = self
        copy.autoStillImageStabilization = enabled
        return copy
    }

    // MARK: - Build

    /// Constructs `AVCapturePhotoSettings` from the current configuration.
    ///
    /// Properties that were not explicitly set remain at `AVCapturePhotoSettings` defaults.
    public func build() -> AVCapturePhotoSettings {
        let settings = if let codecType {
            AVCapturePhotoSettings(format: [AVVideoCodecKey: codecType])
        } else {
            AVCapturePhotoSettings()
        }

        if let flashMode {
            settings.flashMode = flashMode
        }

        if let qualityPrioritization {
            settings.photoQualityPrioritization = qualityPrioritization
        }

        if let maxDimensions {
            settings.maxPhotoDimensions = maxDimensions
        }

        if let autoRedEyeReduction {
            settings.isAutoRedEyeReductionEnabled = autoRedEyeReduction
        }

        if let depthDataDelivery {
            settings.isDepthDataDeliveryEnabled = depthDataDelivery
        }

        #if !os(macOS)
            if let autoStillImageStabilization {
                settings.isAutoStillImageStabilizationEnabled = autoStillImageStabilization
            }
        #endif

        return settings
    }
}
