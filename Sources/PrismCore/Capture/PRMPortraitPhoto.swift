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
            portraitSettings = portraitSettings
                .depthDataDelivery(true)
                // Don't embed depth in the JPEG/HEIC payload — we re-encode the photo
                // through our bokeh filter before saving, which would strip the embed
                // anyway, and on iPhone Pro models leaving this true sometimes routes
                // depth exclusively to the embed and leaves `AVCapturePhoto.depthData`
                // with a null `depthDataMap`. Setting false guarantees the depth
                // arrives via the property path we read.
                .embedsDepthDataInPhoto(false)
        }
        if output.isPortraitEffectsMatteDeliveryEnabled {
            portraitSettings = portraitSettings
                .portraitEffectsMatte(true)
                // AVFoundation enforces: `embedsPortraitEffectsMatteInPhoto` cannot be
                // true while `embedsDepthDataInPhoto` is false (matte is derived from
                // depth; an embedded matte without embedded depth is rejected as
                // invalid). We disable depth embed above, so we must also disable
                // matte embed here — otherwise `capturePhotoWithSettings:` throws
                // NSInvalidArgumentException at capture time. The matte still arrives
                // via `AVCapturePhoto.portraitEffectsMatte`.
                .embedsPortraitEffectsMatteInPhoto(false)
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
