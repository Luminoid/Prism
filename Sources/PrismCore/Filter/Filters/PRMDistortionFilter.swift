import CoreImage

// MARK: - Bump

public struct PRMBumpDistortionFilter: PRMFilter {
    public let radius: Float
    public let scale: Float

    public init(radius: Float = 300.0, scale: Float = 0.5) {
        self.radius = radius
        self.scale = scale
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
    }
}

// MARK: - Twirl

public struct PRMTwirlDistortionFilter: PRMFilter {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 300.0, angle: Float = .pi) {
        self.radius = radius
        self.angle = angle
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CITwirlDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
    }
}

// MARK: - Pinch

public struct PRMPinchDistortionFilter: PRMFilter {
    public let radius: Float
    public let scale: Float

    public init(radius: Float = 300.0, scale: Float = 0.5) {
        self.radius = radius
        self.scale = scale
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPinchDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
    }
}

// MARK: - Vortex

public struct PRMVortexDistortionFilter: PRMFilter {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 300.0, angle: Float = 56.55) {
        self.radius = radius
        self.angle = angle
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIVortexDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
    }
}
