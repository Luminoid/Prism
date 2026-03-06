import CoreImage

// MARK: - PRMPixellateFilter

/// Applies a pixellation effect using CIPixellate.
///
/// - Parameter scale: The pixel block size (default 8.0).
public final class PRMPixellateFilter: PRMCameraFilter, @unchecked Sendable {
    public let scale: Float

    public init(scale: Float = 8.0) {
        self.scale = scale
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: scale,
            kCIInputCenterKey: center,
        ])
    }
}

// MARK: - PRMComicFilter

/// Applies a comic book/halftone effect using CIComicEffect.
public final class PRMComicFilter: PRMCameraFilter, @unchecked Sendable {
    public init() {}

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIComicEffect")
    }
}

// MARK: - PRMPointillizeFilter

/// Applies a pointillism effect using CIPointillize.
///
/// - Parameter radius: The dot radius (default 20.0).
public final class PRMPointillizeFilter: PRMCameraFilter, @unchecked Sendable {
    public let radius: Float

    public init(radius: Float = 20.0) {
        self.radius = radius
    }

    public func render(image: CIImage) -> CIImage? {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPointillize", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputCenterKey: center,
        ])
    }
}

// MARK: - PRMEdgesFilter

/// Detects and highlights edges using CIEdges.
///
/// - Parameter intensity: Edge detection intensity (default 1.0).
public final class PRMEdgesFilter: PRMCameraFilter, @unchecked Sendable {
    public let intensity: Float

    public init(intensity: Float = 1.0) {
        self.intensity = intensity
    }

    public func render(image: CIImage) -> CIImage? {
        image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: intensity])
    }
}
