import CoreImage

/// A value-type filter that transforms a `CIImage`.
///
/// Implement this protocol for custom filters. Built-in filters are zero-config structs
/// (e.g., ``PRMSepiaFilter``).
///
/// Return the input image unchanged for "pass-through" behavior; the protocol does not allow
/// returning nil, matching the data-oriented Core Image model.
public protocol PRMFilter: Sendable {
    /// Applies the filter to the input image and returns the result.
    func render(_ image: CIImage) -> CIImage
}

public extension PRMFilter {
    /// CIVector pointing at the geometric center of `image`'s extent. Used by every
    /// center-based built-in filter (Bump, Twirl, Pinch, Vortex, Pixellate, Pointillize)
    /// so the same `image.extent.midX / midY` math doesn't live in six places.
    static func ciCenter(of image: CIImage) -> CIVector {
        CIVector(x: image.extent.midX, y: image.extent.midY)
    }

    /// Clamps a filter's output extent back to the input frame. Required for any filter
    /// whose CoreImage primitive can return an infinite extent (distortion, edges) —
    /// downstream `CIContext.heifRepresentation` / `jpegRepresentation` silently return
    /// nil on infinite-extent inputs, which masquerades as a HEIC-fallback-to-JPEG bug
    /// or a corrupted output. Cropping at the filter boundary keeps the chain WYSIWYG.
    static func cropped(_ output: CIImage, to source: CIImage) -> CIImage {
        output.cropped(to: source.extent)
    }
}

// MARK: - Pass-through filter

/// A no-op filter useful as a sentinel.
public struct PRMPassThroughFilter: PRMFilter {
    public init() {}
    public func render(_ image: CIImage) -> CIImage {
        image
    }
}
