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
        // Force HEIC for Portrait. The iOS Photos.app's Portrait UI (badge + Edit-mode
        // depth slider) only fires for HEIC files with Apple-written maker-note + depth
        // aux. JPEG with embedded disparity aux is technically a valid depth photo
        // (CGImageSourceCopyAuxiliaryDataInfoAtIndex round-trips it), but Photos.app
        // treats it as a flat still — no badge, no slider. HEVC is available on every
        // device that supports Portrait (iPhone 7+), so this is safe to force.
        if portraitSettings.codec == nil, output.availablePhotoCodecTypes.contains(.hevc) {
            portraitSettings = portraitSettings.codec(.hevc)
        }
        if output.isDepthDataDeliveryEnabled {
            // Embed depth into the HEIC payload so AVFoundation writes the Apple-format
            // maker-note + aux tracks that Photos.app recognizes. The prior `false` path
            // existed because the package re-encoded the photo through a CIImage bokeh
            // filter (which strips aux) and read depth via the property path. We now
            // save the original `fileDataRepresentation()` unchanged, so embedding is
            // the right answer — and on iPhone Pro models the deferred-photo issue that
            // motivated the false path is no longer triggered by this code path.
            portraitSettings = portraitSettings
                .depthDataDelivery(true)
                .embedsDepthDataInPhoto(true)
        }
        if output.isPortraitEffectsMatteDeliveryEnabled {
            // Matte embed requires depth embed (AVFoundation invariant: matte is derived
            // from depth, and an embedded matte without embedded depth is rejected as
            // invalid). Both are true together above.
            portraitSettings = portraitSettings
                .portraitEffectsMatte(true)
                .embedsPortraitEffectsMatteInPhoto(true)
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
