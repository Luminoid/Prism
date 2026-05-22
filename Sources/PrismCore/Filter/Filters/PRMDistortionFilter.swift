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
        let output = image.applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: Self.ciCenter(of: image),
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
        return Self.cropped(output, to: image)
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
        let output = image.applyingFilter("CITwirlDistortion", parameters: [
            kCIInputCenterKey: Self.ciCenter(of: image),
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
        return Self.cropped(output, to: image)
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
        let output = image.applyingFilter("CIPinchDistortion", parameters: [
            kCIInputCenterKey: Self.ciCenter(of: image),
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
        return Self.cropped(output, to: image)
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
        let output = image.applyingFilter("CIVortexDistortion", parameters: [
            kCIInputCenterKey: Self.ciCenter(of: image),
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
        return Self.cropped(output, to: image)
    }
}
