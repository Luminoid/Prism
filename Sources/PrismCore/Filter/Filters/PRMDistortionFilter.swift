import CoreImage

// MARK: - PRMBumpDistortionFilter

/// Applies a bump distortion using CIBumpDistortion.
///
/// - Parameters:
///   - radius: The area of effect (default 300.0).
///   - scale: The bump height (-1.0 to 1.0, default 0.5).
public final class PRMBumpDistortionFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float
    public let scale: Float

    public init(radius: Float = 300.0, scale: Float = 0.5) {
        self.radius = radius
        self.scale = scale
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
    }
}

// MARK: - PRMTwirlDistortionFilter

/// Applies a twirl distortion using CITwirlDistortion.
///
/// - Parameters:
///   - radius: The area of effect (default 300.0).
///   - angle: The twirl angle in radians (default π).
public final class PRMTwirlDistortionFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 300.0, angle: Float = .pi) {
        self.radius = radius
        self.angle = angle
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CITwirlDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
    }
}

// MARK: - PRMPinchDistortionFilter

/// Applies a pinch distortion using CIPinchDistortion.
///
/// - Parameters:
///   - radius: The area of effect (default 300.0).
///   - scale: The pinch intensity (0.0 to 1.0, default 0.5).
public final class PRMPinchDistortionFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float
    public let scale: Float

    public init(radius: Float = 300.0, scale: Float = 0.5) {
        self.radius = radius
        self.scale = scale
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPinchDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale,
        ])
    }
}

// MARK: - PRMVortexDistortionFilter

/// Applies a vortex distortion using CIVortexDistortion.
///
/// - Parameters:
///   - radius: The area of effect (default 300.0).
///   - angle: The vortex angle in radians (default 56.55, ~10 full rotations).
public final class PRMVortexDistortionFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float
    public let angle: Float

    public init(radius: Float = 300.0, angle: Float = 56.55) {
        self.radius = radius
        self.angle = angle
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIVortexDistortion", parameters: [
            kCIInputCenterKey: center,
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: angle,
        ])
    }
}
