import CoreImage
import CoreMedia
import CoreVideo

/// A multi-filter renderer that chains filters sequentially with per-filter intensity.
///
/// CoreImage automatically fuses chained kernels into a single GPU pass for performance.
/// Each filter can be blended with the prior step at any intensity from 0 (no effect) to 1
/// (full effect) via a correct `mix(prev, filtered, intensity)` using `CIBlendWithMask`.
///
/// **Bug fix from the previous implementation**: the old chain composited the filtered image
/// over the **original input** for intermediate steps, throwing away upstream filter work.
/// This version correctly lerps against the **previous step's output**.
///
/// ```swift
/// let chain = PRMFilterChain(context: renderContext, description: "Warm Vignette", filters: [
///     PRMFilterChain.Entry(filter: PRMSepiaFilter(intensity: 0.6), intensity: 0.6),
///     PRMFilterChain.Entry(filter: PRMVignetteFilter(), intensity: 1.0),
/// ])
/// ```
public final class PRMFilterChain: PRMFilterRenderer, @unchecked Sendable {
    // MARK: - Types

    /// A filter entry with a blend intensity (0...1).
    public struct Entry: Sendable {
        public let filter: any PRMFilter
        /// Blend intensity, clamped to 0...1.
        public let intensity: Float

        public init(filter: any PRMFilter, intensity: Float = 1.0) {
            self.filter = filter
            self.intensity = min(max(intensity, 0.0), 1.0)
        }
    }

    // MARK: - Properties

    public let description: String
    public private(set) var isPrepared = false
    public private(set) var outputFormatDescription: CMFormatDescription?
    public private(set) var inputFormatDescription: CMFormatDescription?

    public private(set) var entries: [Entry]
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    private let context: PRMRenderContext
    private var outputColorSpace: CGColorSpace?
    private var outputPixelBufferPool: CVPixelBufferPool?

    // MARK: - Init

    public init(
        context: PRMRenderContext,
        description: String,
        entries: [Entry] = []
    ) {
        self.context = context
        self.description = description
        self.entries = entries
    }

    // MARK: - Mutation

    public func append(_ filter: any PRMFilter, intensity: Float = 1.0) {
        entries.append(Entry(filter: filter, intensity: intensity))
    }

    public func append(_ entry: Entry) {
        entries.append(entry)
    }

    public func remove(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        entries.remove(at: index)
    }

    public func removeAll() {
        entries.removeAll()
    }

    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }

    public func setIntensity(_ intensity: Float, at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let current = entries[index]
        entries[index] = Entry(filter: current.filter, intensity: intensity)
    }

    public func move(from source: Int, to destination: Int) {
        guard source >= 0, source < entries.count else { return }
        guard destination >= 0, destination < entries.count else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: destination)
    }

    // MARK: - PRMFilterRenderer

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
        isPrepared = true
    }

    public func reset() {
        outputColorSpace = nil
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        isPrepared = false
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard isPrepared, let pool = outputPixelBufferPool else { return nil }
        guard !entries.isEmpty else { return pixelBuffer }

        let sourceImage = CIImage(cvImageBuffer: pixelBuffer)
        var currentImage = sourceImage

        for entry in entries {
            let filtered = entry.filter.render(currentImage)

            switch entry.intensity {
            case let intensity where intensity <= 0.0:
                // 0 = no effect; carry previous step forward unchanged.
                continue
            case let intensity where intensity >= 1.0:
                currentImage = filtered
            case let intensity:
                // Correct intensity blend: mix(currentImage, filtered, intensity).
                //
                // Build a constant-luminance grayscale mask at value `intensity` then use
                // CIBlendWithMask, which returns mask·image + (1−mask)·background. Cropping the
                // mask to the filtered image's extent matches CoreImage's infinite-extent semantics.
                let maskColor = CIColor(
                    red: CGFloat(intensity),
                    green: CGFloat(intensity),
                    blue: CGFloat(intensity),
                    alpha: 1.0
                )
                let mask = CIImage(color: maskColor).cropped(to: filtered.extent)
                currentImage = filtered.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: currentImage,
                    kCIInputMaskImageKey: mask,
                ])
            }
        }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let outputPixelBuffer = output else {
            PRMLogger.filter.warning("[\(self.description)] Failed to allocate output pixel buffer")
            return nil
        }

        context.ciContext.render(
            currentImage,
            to: outputPixelBuffer,
            bounds: currentImage.extent,
            colorSpace: outputColorSpace
        )
        return outputPixelBuffer
    }
}
