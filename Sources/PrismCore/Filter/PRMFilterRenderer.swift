import CoreMedia
import CoreVideo

/// A renderer that processes live video frames through a filter pipeline.
///
/// Renderers manage their own pixel buffer pools. Call ``prepare(with:outputRetainedBufferCountHint:)``
/// before rendering, and ``reset()`` when switching filters or stopping the pipeline.
public protocol PRMFilterRenderer: AnyObject, Sendable {
    /// Human-readable description (e.g., `"Sepia"`).
    var description: String { get }

    /// Whether the renderer is prepared and ready to process frames.
    var isPrepared: Bool { get }

    /// The output pixel buffer format description, or `nil` if not prepared.
    var outputFormatDescription: CMFormatDescription? { get }

    /// The input pixel buffer format description, or `nil` if not prepared.
    var inputFormatDescription: CMFormatDescription? { get }

    /// Prepares the renderer for the given input format.
    func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int)

    /// Releases resources. Re-prepare before rendering again.
    func reset()

    /// Renders an input pixel buffer through the filter.
    /// Returns the (possibly filtered) buffer, or `nil` on failure.
    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
}
