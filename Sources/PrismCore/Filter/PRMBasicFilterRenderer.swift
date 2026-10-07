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

    public var isPrepared: Bool {
        chain.isPrepared
    }

    public var outputFormatDescription: CMFormatDescription? {
        chain.outputFormatDescription
    }

    public var inputFormatDescription: CMFormatDescription? {
        chain.inputFormatDescription
    }

    /// A one-entry chain does the pooling, locking and rendering, so both renderers share
    /// one implementation (and one thread-safety story: state is snapshotted under a lock,
    /// so `reset()` from another thread can't tear a render).
    private let chain: PRMFilterChain
    private let filterFactory: @Sendable () -> any PRMFilter

    /// - Parameters:
    ///   - context: Shared Metal-backed CIContext.
    ///   - description: Display name for this renderer.
    ///   - filterFactory: Creates a fresh `PRMFilter` instance when the renderer is prepared.
    public init(
        context: PRMRenderContext,
        description: String,
        filterFactory: @escaping @Sendable () -> any PRMFilter
    ) {
        self.description = description
        self.filterFactory = filterFactory
        chain = PRMFilterChain(context: context, description: description)
    }

    public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        chain.replace([PRMFilterChain.Entry(filter: filterFactory())])
        chain.prepare(with: formatDescription, outputRetainedBufferCountHint: outputRetainedBufferCountHint)
    }

    public func reset() {
        chain.reset()
        chain.removeAll()
    }

    public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard chain.isPrepared, !chain.isEmpty else { return nil }
        return chain.render(pixelBuffer: pixelBuffer)
    }
}
