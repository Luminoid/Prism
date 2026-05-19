import CoreImage

// MARK: - Gaussian Blur

public struct PRMGaussianBlurFilter: PRMFilter {
    public let radius: Float

    public init(radius: Float = 10.0) {
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }
}

// MARK: - Motion Blur

public struct PRMMotionBlurFilter: PRMFilter {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 20.0, angle: Float = 0.0) {
        self.radius = radius
        self.angle = angle
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ]).cropped(to: image.extent)
    }
}

// MARK: - Zoom Blur

public struct PRMZoomBlurFilter: PRMFilter {
    public let amount: Float

    public init(amount: Float = 20.0) {
        self.amount = amount
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIZoomBlur", parameters: [
            kCIInputCenterKey: center,
            "inputAmount": amount,
        ]).cropped(to: image.extent)
    }
}
