import CoreImage
import CoreMedia
import CoreVideo
import os

/// A multi-filter renderer that chains multiple `PRMCameraFilter` instances sequentially.
///
/// CoreImage automatically fuses chained filter kernels into a single GPU pass for performance.
/// Each filter can have an intensity (0.0–1.0) that blends the filtered result with the original.
///
/// ```swift
/// let chain = PRMFilterChain(description: "Warm Vignette", filters: [
///     .init(filter: SepiaFilter(), intensity: 0.6),
///     .init(filter: VignetteFilter(), intensity: 1.0),
/// ])
/// pipeline.activeRenderer = chain
/// ```
public final class PRMFilterChain: PRMCameraFilterRenderer, @unchecked Sendable {
    // MARK: - Types

    /// A filter entry with an intensity control.
    public struct FilterEntry: Sendable {
        /// The filter to apply.
        public let filter: any PRMCameraFilter
        /// The blend intensity (0.0 = no effect, 1.0 = full effect).
        public let intensity: Float

        public init(filter: any PRMCameraFilter, intensity: Float = 1.0) {
            self.filter = filter
            self.intensity = min(max(intensity, 0.0), 1.0)
        }
    }

    // MARK: - Properties

    public let description: String
    public private(set) var isPrepared = false
    public private(set) var outputFormatDescription: CMFormatDescription?
    public private(set) var inputFormatDescription: CMFormatDescription?

    /// The current filter entries in the chain.
    public private(set) var filters: [FilterEntry]

    /// The number of filters in the chain.
    public var filterCount: Int {
        filters.count
    }

    private var ciContext: CIContext?
    private var outputColorSpace: CGColorSpace?
    private var outputPixelBufferPool: CVPixelBufferPool?

    // MARK: - Initialization

    /// Creates a filter chain with the given filters.
    ///
    /// - Parameters:
    ///   - description: A human-readable name for this chain.
    ///   - filters: The ordered list of filter entries.
    public init(description: String, filters: [FilterEntry] = []) {
        self.description = description
        self.filters = filters
    }

    // MARK: - Mutation

    /// Appends a filter to the chain.
    public func append(_ filter: any PRMCameraFilter, intensity: Float = 1.0) {
        filters.append(FilterEntry(filter: filter, intensity: intensity))
    }

    /// Removes the filter at the given index.
    public func remove(at index: Int) {
        guard index >= 0, index < filters.count else { return }
        filters.remove(at: index)
    }

    /// Removes all filters from the chain.
    public func removeAll() {
        filters.removeAll()
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
        isPrepared = true
    }

    public func reset() {
        ciContext = nil
        outputColorSpace = nil
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        isPrepared = false
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let ciContext, isPrepared else { return nil }

        // Empty chain = pass-through
        guard !filters.isEmpty else { return pixelBuffer }

        let sourceImage = CIImage(cvImageBuffer: pixelBuffer)
        var currentImage = sourceImage

        // Chain filters sequentially
        for entry in filters {
            guard let filtered = entry.filter.render(image: currentImage) else {
                PRMLogger.filter.debug("[\(self.description)] Filter in chain returned nil, using previous result")
                continue
            }

            if entry.intensity >= 1.0 {
                currentImage = filtered
            } else if entry.intensity <= 0.0 {
                // Skip this filter entirely
                continue
            } else {
                // Blend: lerp between current and filtered
                currentImage = filtered.composited(over: currentImage)
                    .applyingFilter("CISourceOverCompositing", parameters: [:])
                // Use CIBlendWithAlphaMask or manual alpha blending for intensity
                let alpha = CGFloat(entry.intensity)
                currentImage = currentImage.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                ]).composited(over: sourceImage)
                // Re-base for next filter in chain
            }
        }

        // Render to output pixel buffer
        guard let pool = outputPixelBufferPool else { return nil }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)

        guard let outputPixelBuffer = outputBuffer else {
            PRMLogger.filter.warning("[\(self.description)] Failed to allocate output pixel buffer")
            return nil
        }

        ciContext.render(
            currentImage,
            to: outputPixelBuffer,
            bounds: currentImage.extent,
            colorSpace: outputColorSpace,
        )

        return outputPixelBuffer
    }
}
