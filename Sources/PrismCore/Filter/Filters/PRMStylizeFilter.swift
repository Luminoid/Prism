import CoreImage

// MARK: - Pixellate

public struct PRMPixellateFilter: PRMFilter {
    public let scale: Float

    public init(scale: Float = 8.0) {
        self.scale = scale
    }

    public func render(_ image: CIImage) -> CIImage {
        let output = image.applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: scale,
            kCIInputCenterKey: Self.ciCenter(of: image),
        ])
        return Self.cropped(output, to: image)
    }
}

// MARK: - Comic

public struct PRMComicFilter: PRMFilter {
    public init() {}

    public func render(_ image: CIImage) -> CIImage {
        let output = image.applyingFilter("CIComicEffect")
        return Self.cropped(output, to: image)
    }
}

// MARK: - Pointillize

public struct PRMPointillizeFilter: PRMFilter {
    public let radius: Float

    public init(radius: Float = 20.0) {
        self.radius = radius
    }

    public func render(_ image: CIImage) -> CIImage {
        let output = image.applyingFilter("CIPointillize", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputCenterKey: Self.ciCenter(of: image),
        ])
        return Self.cropped(output, to: image)
    }
}

// MARK: - Edges

public struct PRMEdgesFilter: PRMFilter {
    public let intensity: Float

    public init(intensity: Float = 1.0) {
        self.intensity = intensity
    }

    public func render(_ image: CIImage) -> CIImage {
        let output = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: intensity])
        return Self.cropped(output, to: image)
    }
}
