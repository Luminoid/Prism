import CoreImage

// MARK: - PRMGaussianBlurFilter

/// Applies a Gaussian blur using CIGaussianBlur.
///
/// - Parameter radius: The blur radius in pixels (default 10.0).
public final class PRMGaussianBlurFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float

    public init(radius: Float = 10.0) {
        self.radius = radius
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }
}

// MARK: - PRMMotionBlurFilter

/// Applies directional motion blur using CIMotionBlur.
///
/// - Parameters:
///   - radius: The blur distance in pixels (default 20.0).
///   - angle: The blur direction in radians (default 0.0 = horizontal).
public final class PRMMotionBlurFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 20.0, angle: Float = 0.0) {
        self.radius = radius
        self.angle = angle
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ]).cropped(to: image.extent)
    }
}

// MARK: - PRMZoomBlurFilter

/// Applies radial zoom blur using CIZoomBlur.
///
/// - Parameter amount: The zoom amount (default 20.0).
public final class PRMZoomBlurFilter: PRMCameraFilter, @unchecked Sendable {
    public let amount: Float

    public init(amount: Float = 20.0) {
        self.amount = amount
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIZoomBlur", parameters: [
            kCIInputCenterKey: center,
            "inputAmount": amount,
        ]).cropped(to: image.extent)
    }
}
