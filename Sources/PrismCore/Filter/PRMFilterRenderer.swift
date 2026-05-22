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
    ///
    /// **Ownership**: the returned buffer is borrowed from the renderer's internal
    /// `CVPixelBufferPool`. Swift bridging bumps the refcount while the caller holds the
    /// returned value, so synchronous consumers (the data-output queue path,
    /// ``PRMFilterPipeline/onFrame``) are always safe — they finish reading before the
    /// next `render(pixelBuffer:)` call.
    ///
    /// **Asynchronous consumers MUST retain the buffer until they're done**: forwarding
    /// the buffer onto another queue, queuing for ML inference, batching for video
    /// encoding, etc. Letting the reference fall out of scope before the consumer reads
    /// it is the textbook CVPixelBufferPool recycling race — the pool reuses the backing
    /// memory for the next frame and the deferred read sees corrupted pixels (often
    /// visible as torn frames or "previous frame ghosts"). When in doubt, copy via
    /// `CVPixelBufferCreateCopy()` before crossing async boundaries.
    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
}
