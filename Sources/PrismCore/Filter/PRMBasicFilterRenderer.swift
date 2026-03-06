import CoreImage
import CoreMedia
import CoreVideo
import os

/// A composition-based filter renderer that bridges `PRMCameraFilter` to `PRMCameraFilterRenderer`.
///
/// Instead of subclassing (AnimalVision's old pattern), create renderers with a factory closure:
/// ```swift
/// let grayscale = PRMBasicFilterRenderer(description: "Grayscale") { GrayscaleFilter() }
/// ```
///
/// This eliminates all per-filter renderer subclasses — each becomes a one-liner in the consuming app.
public final class PRMBasicFilterRenderer: PRMCameraFilterRenderer, @unchecked Sendable {
    // MARK: - Properties

    public let description: String
    public private(set) var isPrepared = false
    public private(set) var outputFormatDescription: CMFormatDescription?
    public private(set) var inputFormatDescription: CMFormatDescription?

    private let filterFactory: @Sendable () -> any PRMCameraFilter
    private var filter: (any PRMCameraFilter)?
    private var ciContext: CIContext?
    private var outputColorSpace: CGColorSpace?
    private var outputPixelBufferPool: CVPixelBufferPool?

    // MARK: - Initialization

    /// Creates a new renderer with a factory closure that produces the filter.
    ///
    /// - Parameters:
    ///   - description: A human-readable name for this renderer.
    ///   - filterFactory: A closure that creates a fresh `PRMCameraFilter` instance.
    public init(description: String, filterFactory: @escaping @Sendable () -> any PRMCameraFilter) {
        self.description = description
        self.filterFactory = filterFactory
    }

    // MARK: - PRMCameraFilterRenderer

    public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        reset()

        guard let result = PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: formatDescription,
            retainedBufferCountHint: outputRetainedBufferCountHint,
        ) else {
            PRMLogger.filter.error("[\(self.description)] Failed to allocate output buffer pool")
            return
        }

        outputPixelBufferPool = result.bufferPool
        outputColorSpace = result.colorSpace
        outputFormatDescription = result.formatDescription
        inputFormatDescription = formatDescription
        ciContext = CIContext()
        filter = filterFactory()
        isPrepared = true
    }

    public func reset() {
        ciContext = nil
        filter = nil
        outputColorSpace = nil
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        isPrepared = false
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let ciContext, let filter, isPrepared else {
            return nil
        }

        let sourceImage = CIImage(cvImageBuffer: pixelBuffer)

        guard let filteredImage = filter.render(image: sourceImage) else {
            PRMLogger.filter.warning("[\(self.description)] Filter failed to render image")
            return nil
        }

        guard let pool = outputPixelBufferPool else { return nil }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)

        guard let outputPixelBuffer = outputBuffer else {
            PRMLogger.filter.warning("[\(self.description)] Failed to allocate output pixel buffer")
            return nil
        }

        ciContext.render(
            filteredImage,
            to: outputPixelBuffer,
            bounds: filteredImage.extent,
            colorSpace: outputColorSpace,
        )

        return outputPixelBuffer
    }
}
