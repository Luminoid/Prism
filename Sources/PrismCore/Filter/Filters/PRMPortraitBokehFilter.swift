@preconcurrency import AVFoundation
import CoreImage

/// A portrait-style bokeh applied to the background, sharp in the foreground.
///
/// Two modes:
/// - ``init(matte:radius:)`` uses a portrait-effects matte (via `CIBlendWithMask`) to
///   composite a blurred copy under the sharp foreground.
/// - ``init(depthData:focusDistance:radius:)`` uses depth data with `CIDepthBlurEffect`
///   to simulate variable-aperture bokeh.
///
/// Both rely on Core Image filters that ship with iOS, so no extra dependencies.
public struct PRMPortraitBokehFilter: PRMFilter {
    public enum Source: Sendable {
        case matte(CIImage)
        case depth(CIImage, focusDistance: Float)
    }

    public let source: Source
    public let radius: Float

    public init(matte: CIImage, radius: Float = 18.0) {
        source = .matte(matte)
        self.radius = radius
    }

    /// - Parameters:
    ///   - depthData: A disparity image (from `AVDepthData`).
    ///   - focusDistance: Where the in-focus region sits vertically, normalized from `0`
    ///     (bottom of the frame) to `1` (top), centered horizontally. Clamped to `0...1`.
    ///   - radius: Simulated aperture strength (`inputAperture`).
    public init(depthData: CIImage, focusDistance: Float = 0.5, radius: Float = 18.0) {
        source = .depth(depthData, focusDistance: focusDistance)
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        switch source {
        case let .matte(matte):
            let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radius,
            ]).cropped(to: image.extent)
            let resizedMatte = matte
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: image.extent.height / max(matte.extent.height, 1),
                ])
                .cropped(to: image.extent)
            return image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: resizedMatte,
            ]).cropped(to: image.extent)
        case let .depth(depth, focusDistance):
            // `CIDepthBlurEffect` has no center key (setting one raises
            // `NSUnknownKeyException`); focus comes from `inputFocusRect`, in normalized
            // image coordinates.
            return image.applyingFilter("CIDepthBlurEffect", parameters: [
                "inputDisparityImage": depth,
                "inputAperture": radius,
                "inputFocusRect": CIVector(cgRect: Self.focusRect(forFocusDistance: focusDistance)),
                "inputLumaNoiseScale": 0.0,
                "inputScaleFactor": NSNumber(value: 1.0),
            ]).cropped(to: image.extent)
        }
    }

    /// A normalized focus rect, 20 % of the frame on each side, centered horizontally at
    /// the `focusDistance` height and kept inside the unit square.
    static func focusRect(forFocusDistance focusDistance: Float) -> CGRect {
        let size: CGFloat = 0.2
        let center = focusDistance.isFinite ? CGFloat(min(max(focusDistance, 0), 1)) : 0.5
        let originY = min(max(center - size / 2, 0), 1 - size)
        return CGRect(x: 0.5 - size / 2, y: originY, width: size, height: size)
    }
}
