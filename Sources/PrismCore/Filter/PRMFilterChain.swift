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

    public var isPrepared: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPrepared
    }

    public var outputFormatDescription: CMFormatDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _outputFormatDescription
    }

    public var inputFormatDescription: CMFormatDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _inputFormatDescription
    }

    public var entries: [Entry] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _entries
    }

    public var count: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _entries.count
    }

    public var isEmpty: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _entries.isEmpty
    }

    // MARK: - Private storage

    private var _isPrepared = false
    private var _outputFormatDescription: CMFormatDescription?
    private var _inputFormatDescription: CMFormatDescription?
    private var _entries: [Entry]
    private var outputColorSpace: CGColorSpace?
    private var outputPixelBufferPool: CVPixelBufferPool?
    private let context: PRMRenderContext
    private let stateLock = NSLock()

    // MARK: - Init

    public init(
        context: PRMRenderContext,
        description: String,
        entries: [Entry] = []
    ) {
        self.context = context
        self.description = description
        _entries = entries
    }

    // MARK: - Mutation

    public func append(_ filter: any PRMFilter, intensity: Float = 1.0) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _entries.append(Entry(filter: filter, intensity: intensity))
    }

    public func append(_ entry: Entry) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _entries.append(entry)
    }

    public func remove(at index: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard index >= 0, index < _entries.count else { return }
        _entries.remove(at: index)
    }

    public func removeAll() {
        stateLock.lock()
        defer { stateLock.unlock() }
        _entries.removeAll()
    }

    public func replace(_ entries: [Entry]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _entries = entries
    }

    public func setIntensity(_ intensity: Float, at index: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard index >= 0, index < _entries.count else { return }
        let current = _entries[index]
        _entries[index] = Entry(filter: current.filter, intensity: intensity)
    }

    public func move(from source: Int, to destination: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard source >= 0, source < _entries.count else { return }
        guard destination >= 0, destination < _entries.count else { return }
        let entry = _entries.remove(at: source)
        _entries.insert(entry, at: destination)
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

        stateLock.lock()
        outputPixelBufferPool = allocation.bufferPool
        outputColorSpace = allocation.colorSpace
        _outputFormatDescription = allocation.formatDescription
        _inputFormatDescription = formatDescription
        _isPrepared = true
        stateLock.unlock()
    }

    public func reset() {
        stateLock.lock()
        outputColorSpace = nil
        outputPixelBufferPool = nil
        _outputFormatDescription = nil
        _inputFormatDescription = nil
        _isPrepared = false
        stateLock.unlock()
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Snapshot under one lock so the render pass sees a consistent (entries, pool) view —
        // a concurrent `remove(at:)` or `reset()` can't tear the iteration.
        stateLock.lock()
        let prepared = _isPrepared
        let pool = outputPixelBufferPool
        let entriesSnapshot = _entries
        let colorSpace = outputColorSpace
        stateLock.unlock()

        guard prepared, let pool else { return nil }
        guard !entriesSnapshot.isEmpty else { return pixelBuffer }

        let sourceImage = CIImage(cvImageBuffer: pixelBuffer)
        let currentImage = Self.apply(entriesSnapshot, to: sourceImage)

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
            colorSpace: colorSpace
        )
        return outputPixelBuffer
    }

    /// Apply a snapshot of chain entries to a CIImage, returning the blended result.
    /// Pure CoreImage in/out — no pixel buffer pool, no GPU render — so the same code
    /// path can drive both the live preview's `render(pixelBuffer:)` and the still
    /// capture's filter encode (``PRMPhotoCapture/capturePhoto(settings:applyingChain:context:willCapture:)``).
    /// Empty entries returns the source unchanged.
    ///
    /// Intensity semantics:
    /// - `≤ 0`: skip the entry, carry previous step forward.
    /// - `≥ 1`: replace previous step with filtered output.
    /// - in between: `CIBlendWithMask` against the previous step using a
    ///   constant-luminance grayscale mask — i.e. `mix(prev, filtered, intensity)`.
    public static func apply(_ entries: [Entry], to source: CIImage) -> CIImage {
        guard !entries.isEmpty else { return source }
        var currentImage = source
        for entry in entries {
            let filtered = entry.filter.render(currentImage)
            switch entry.intensity {
            case let intensity where intensity <= 0.0:
                continue
            case let intensity where intensity >= 1.0:
                currentImage = filtered
            case let intensity:
                // Build a constant-luminance grayscale mask at value `intensity` then use
                // CIBlendWithMask, which returns mask·image + (1−mask)·background. Cropping
                // the mask to the filtered image's extent matches CoreImage's
                // infinite-extent semantics.
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
        return currentImage
    }
}
