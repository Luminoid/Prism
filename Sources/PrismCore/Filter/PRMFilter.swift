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

// MARK: - Pass-through filter

/// A no-op filter useful as a sentinel.
public struct PRMPassThroughFilter: PRMFilter {
    public init() {}
    public func render(_ image: CIImage) -> CIImage {
        image
    }
}
