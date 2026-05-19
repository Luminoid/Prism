import CoreMedia
import CoreVideo

/// A single video frame delivered by ``PRMFilterPipeline``.
///
/// Bundles the processed pixel buffer with its presentation timestamp and format description
/// for downstream consumers (preview view, video recorder, ML pipelines).
///
/// Marked `@unchecked Sendable` because `CVPixelBuffer` and `CMFormatDescription` are Core
/// Foundation reference types that are safe to *pass across* threads. `CVPixelBuffer` is
/// mutable — its IOSurface can be locked for write — so receivers must not lock for writing
/// while the producer is still rendering. The pipeline only writes the buffer from the
/// data-output queue and surfaces it read-only to consumers.
public struct PRMVideoFrame: @unchecked Sendable {
    /// The (possibly filtered) pixel buffer.
    public let pixelBuffer: CVPixelBuffer

    /// The presentation timestamp of the source sample buffer.
    public let timestamp: CMTime

    /// The format description of the source sample buffer.
    public let formatDescription: CMFormatDescription

    public init(pixelBuffer: CVPixelBuffer, timestamp: CMTime, formatDescription: CMFormatDescription) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.formatDescription = formatDescription
    }
}
