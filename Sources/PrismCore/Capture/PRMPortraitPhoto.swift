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
    /// ``PRMCameraConfiguration``. Requests HEVC, embedded depth and the embedded matte
    /// according to what the live photo output delivers at capture time (checked after the
    /// readiness wait, so a reconfigure can't leave a request the output would reject).
    /// Returns a photo with `nil` ancillaries when the output doesn't deliver them for the
    /// active device and format, and with manual exposure (bracketed captures carry none).
    func capturePortraitPhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        applying filter: (any PRMFilter)? = nil,
        context: PRMRenderContext? = nil,
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMPortraitPhoto {
        let photo = try await capturePhoto(
            settings: settings,
            filterRecipe: filter.map { .single($0, context: context) } ?? .none,
            willCapture: willCapture,
            portrait: true
        )
        return PRMPortraitPhoto(
            photo: photo,
            depthData: photo.underlyingPhoto.depthData,
            portraitEffectsMatte: photo.underlyingPhoto.portraitEffectsMatte
        )
    }
}
