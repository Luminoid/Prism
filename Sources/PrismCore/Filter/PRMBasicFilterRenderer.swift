import CoreImage
import CoreMedia
import CoreVideo

/// A composition-based renderer that wraps a single ``PRMFilter`` for live video.
///
/// Shares the provided ``PRMRenderContext`` (so one Metal-backed `CIContext` covers the
/// whole pipeline). Allocates its own pixel-buffer pool sized to the input format.
///
/// ```swift
/// let renderer = PRMBasicFilterRenderer(
///     context: renderContext,
///     description: "Sepia"
/// ) { PRMSepiaFilter(intensity: 0.8) }
/// ```
public final class PRMBasicFilterRenderer: PRMFilterRenderer, @unchecked Sendable {
    public let description: String
    public private(set) var isPrepared = false
    public private(set) var outputFormatDescription: CMFormatDescription?
    public private(set) var inputFormatDescription: CMFormatDescription?

    private let context: PRMRenderContext
    private let filterFactory: @Sendable () -> any PRMFilter
    private var filter: (any PRMFilter)?
    private var outputColorSpace: CGColorSpace?
    private var outputPixelBufferPool: CVPixelBufferPool?

    /// - Parameters:
    ///   - context: Shared Metal-backed CIContext.
    ///   - description: Display name for this renderer.
    ///   - filterFactory: Creates a fresh `PRMFilter` instance when the renderer is prepared.
    public init(
        context: PRMRenderContext,
        description: String,
        filterFactory: @escaping @Sendable () -> any PRMFilter
    ) {
        self.context = context
        self.description = description
        self.filterFactory = filterFactory
    }

    public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        reset()

        guard let allocation = PRMBufferPoolAllocator.allocate(
            with: formatDescription,
            retainedBufferCountHint: outputRetainedBufferCountHint
        ) else {
            PRMLogger.filter.error("[\(self.description)] Failed to allocate output buffer pool")
            return
        }

        outputPixelBufferPool = allocation.bufferPool
        outputColorSpace = allocation.colorSpace
        outputFormatDescription = allocation.formatDescription
        inputFormatDescription = formatDescription
        filter = filterFactory()
        isPrepared = true
    }

    public func reset() {
        filter = nil
        outputColorSpace = nil
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        isPrepared = false
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard isPrepared, let filter, let pool = outputPixelBufferPool else { return nil }

        let sourceImage = CIImage(cvImageBuffer: pixelBuffer)
        let filtered = filter.render(sourceImage)

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let outputPixelBuffer = output else {
            PRMLogger.filter.warning("[\(self.description)] Failed to allocate output pixel buffer")
            return nil
        }

        context.ciContext.render(
            filtered,
            to: outputPixelBuffer,
            bounds: filtered.extent,
            colorSpace: outputColorSpace
        )
        return outputPixelBuffer
    }
}
