import CoreImage

// MARK: - PRMBrightnessFilter

/// Adjusts image brightness using CIColorControls.
///
/// - Parameter value: Brightness adjustment (-1.0 to 1.0, default 0.0).
public final class PRMBrightnessFilter: PRMCameraFilter, @unchecked Sendable {
    public let value: Float

    public init(value: Float = 0.0) {
        self.value = value
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: value])
    }
}

// MARK: - PRMContrastFilter

/// Adjusts image contrast using CIColorControls.
///
/// - Parameter value: Contrast multiplier (0.0 to 4.0, default 1.0).
public final class PRMContrastFilter: PRMCameraFilter, @unchecked Sendable {
    public let value: Float

    public init(value: Float = 1.0) {
        self.value = value
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: value])
    }
}

// MARK: - PRMSaturationFilter

/// Adjusts image color saturation using CIColorControls.
///
/// - Parameter value: Saturation multiplier (0.0 = grayscale, 1.0 = original, 2.0+ = oversaturated).
public final class PRMSaturationFilter: PRMCameraFilter, @unchecked Sendable {
    public let value: Float

    public init(value: Float = 1.0) {
        self.value = value
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: value])
    }
}

// MARK: - PRMHueRotationFilter

/// Rotates image hue using CIHueAdjust.
///
/// - Parameter angle: Hue rotation in radians.
public final class PRMHueRotationFilter: PRMCameraFilter, @unchecked Sendable {
    public let angle: Float

    public init(angle: Float = 0.0) {
        self.angle = angle
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: angle])
    }
}
