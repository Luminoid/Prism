import CoreImage

/// A filter that transforms a `CIImage` for still-photo capture or preview.
///
/// Implement this protocol to create custom camera filters.
/// Each filter receives a `CIImage` and returns a processed result.
///
/// ```swift
/// struct GrayscaleFilter: PRMCameraFilter {
///     func render(image: CIImage) -> CIImage? {
///         image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
///     }
/// }
/// ```
public protocol PRMCameraFilter: AnyObject, Sendable {
    /// Applies the filter to the input image.
    ///
    /// - Parameter image: The source camera frame.
    /// - Returns: The filtered image, or `nil` if the filter cannot be applied.
    func render(image: CIImage) -> CIImage?
}
