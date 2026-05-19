import CoreImage

// MARK: - Pixellate

public struct PRMPixellateFilter: PRMFilter {
    public let scale: Float

    public init(scale: Float = 8.0) {
        self.scale = scale
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: scale,
            kCIInputCenterKey: center,
        ])
    }
}

// MARK: - Comic

public struct PRMComicFilter: PRMFilter {
    public init() {}

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIComicEffect")
    }
}

// MARK: - Pointillize

public struct PRMPointillizeFilter: PRMFilter {
    public let radius: Float

    public init(radius: Float = 20.0) {
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        let center = CIVector(x: image.extent.midX, y: image.extent.midY)
        return image.applyingFilter("CIPointillize", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputCenterKey: center,
        ])
    }
}

// MARK: - Edges

public struct PRMEdgesFilter: PRMFilter {
    public let intensity: Float

    public init(intensity: Float = 1.0) {
        self.intensity = intensity
    }

    public func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: intensity])
    }
}
