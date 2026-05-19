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

    public init(depthData: CIImage, focusDistance: Float = 0.5, radius: Float = 18.0) {
        source = .depth(depthData, focusDistance: focusDistance)
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        switch source {
        case let .matte(matte):
            let blurred = image.applyingFilter("CIGaussianBlur", parameters: [
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
            return image.applyingFilter("CIDepthBlurEffect", parameters: [
                "inputDisparityImage": depth,
                "inputAperture": radius,
                "inputFocusRect": CIVector(cgRect: image.extent),
                "inputLumaNoiseScale": 0.0,
                "inputScaleFactor": NSNumber(value: 1.0),
                kCIInputCenterKey: CIVector(x: 0.5, y: CGFloat(focusDistance)),
            ]).cropped(to: image.extent)
        }
    }
}
