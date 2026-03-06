import CoreMedia
import CoreVideo

/// A renderer that processes live video frames through a filter pipeline.
///
/// Renderers manage their own pixel buffer pools for efficient real-time processing.
/// Call `prepare(with:outputRetainedBufferCountHint:)` before rendering,
/// and `reset()` when switching filters or stopping the pipeline.
public protocol PRMCameraFilterRenderer: AnyObject, Sendable {
    /// A human-readable description of this renderer (e.g., `"Grayscale"`).
    var description: String { get }

    /// Whether the renderer has been prepared and is ready to process frames.
    var isPrepared: Bool { get }

    /// The format description of the renderer's output pixel buffers, or `nil` if not prepared.
    var outputFormatDescription: CMFormatDescription? { get }

    /// The format description of the expected input pixel buffers, or `nil` if not prepared.
    var inputFormatDescription: CMFormatDescription? { get }

    /// Prepares the renderer for processing frames of the given format.
    ///
    /// - Parameters:
    ///   - formatDescription: The format of incoming pixel buffers.
    ///   - outputRetainedBufferCountHint: How many output buffers to keep in the pool.
    func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int)

    /// Releases all resources. The renderer must be re-prepared before rendering again.
    func reset()

    /// Renders a pixel buffer through the filter.
    ///
    /// - Parameter pixelBuffer: The input video frame.
    /// - Returns: The filtered frame, or `nil` if rendering fails.
    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
}
