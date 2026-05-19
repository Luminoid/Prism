import CoreImage

// MARK: - Brightness

/// Adjusts image brightness via CIColorControls.
public struct PRMBrightnessFilter: PRMFilter {
    public let value: Float

    public init(value: Float = 0.0) {
        self.value = value
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: value])
    }
}

// MARK: - Contrast

/// Adjusts image contrast via CIColorControls.
public struct PRMContrastFilter: PRMFilter {
    public let value: Float

    public init(value: Float = 1.0) {
        self.value = value
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: value])
    }
}

// MARK: - Saturation

/// Adjusts image saturation via CIColorControls.
public struct PRMSaturationFilter: PRMFilter {
    public let value: Float

    public init(value: Float = 1.0) {
        self.value = value
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: value])
    }
}

// MARK: - Hue Rotation

/// Rotates image hue via CIHueAdjust.
public struct PRMHueRotationFilter: PRMFilter {
    /// Rotation in radians.
    public let angle: Float

    public init(angle: Float = 0.0) {
        self.angle = angle
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: angle])
    }
}

// MARK: - Grayscale

/// Desaturates the image (CIColorControls with saturation = 0).
public struct PRMGrayscaleFilter: PRMFilter {
    public init() {}

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }
}

// MARK: - Sepia

/// Applies a sepia tone via CISepiaTone.
public struct PRMSepiaFilter: PRMFilter {
    public let intensity: Float

    public init(intensity: Float = 0.8) {
        self.intensity = intensity
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: intensity])
    }
}

// MARK: - Vignette

/// Darkens the edges of the frame via CIVignette.
public struct PRMVignetteFilter: PRMFilter {
    public let intensity: Float
    public let radius: Float

    public init(intensity: Float = 1.5, radius: Float = 2.0) {
        self.intensity = intensity
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: intensity,
            kCIInputRadiusKey: radius,
        ])
    }
}
