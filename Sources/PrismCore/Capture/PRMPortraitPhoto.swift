@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// A photo captured with depth and/or portrait-effects-matte ancillary data.
///
/// Produced by ``PRMPhotoCapture/capturePortraitPhoto(settings:applying:context:willCapture:)``.
public struct PRMPortraitPhoto: @unchecked Sendable {
    /// The base photo (JPEG/HEIC data + metadata + underlying AVCapturePhoto).
    public let photo: PRMPhoto

    /// Depth data if delivered by the device (LiDAR / dual-pixel / dual-lens disparity).
    public let depthData: AVDepthData?

    /// Portrait effects matte if the photo output supports it for the active scene.
    public let portraitEffectsMatte: AVPortraitEffectsMatte?

    public init(
        photo: PRMPhoto,
        depthData: AVDepthData?,
        portraitEffectsMatte: AVPortraitEffectsMatte?
    ) {
        self.photo = photo
        self.depthData = depthData
        self.portraitEffectsMatte = portraitEffectsMatte
    }
}

public extension PRMPhotoCapture {
    /// Captures a photo with depth and portrait effects matte ancillary data, if available.
    ///
    /// Requires `enableDepthDataDelivery` and/or `enablePortraitEffectsMatteDelivery` on
    /// ``PRMCameraConfiguration``. Silently returns a photo with `nil` ancillaries if the
    /// output doesn't support them for the active device/format.
    func capturePortraitPhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        applying filter: (any PRMFilter)? = nil,
        context: PRMRenderContext? = nil,
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMPortraitPhoto {
        var portraitSettings = settings
        if output.isDepthDataDeliveryEnabled {
            portraitSettings = portraitSettings.depthDataDelivery(true)
        }
        if output.isPortraitEffectsMatteDeliveryEnabled {
            portraitSettings = portraitSettings.portraitEffectsMatte(true)
        }
        let photo = try await capturePhoto(
            settings: portraitSettings,
            applying: filter,
            context: context,
            willCapture: willCapture
        )
        return PRMPortraitPhoto(
            photo: photo,
            depthData: photo.underlyingPhoto.depthData,
            portraitEffectsMatte: photo.underlyingPhoto.portraitEffectsMatte
        )
    }
}
