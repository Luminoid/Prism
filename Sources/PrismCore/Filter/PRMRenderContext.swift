import CoreImage
import Metal

/// Shared rendering resources for the filter pipeline.
///
/// Apple's guidance (WWDC '20, "Optimize the Core Image pipeline for your video app") is to
/// create exactly **one** `CIContext` per view or pipeline, bind it to a Metal device, and
/// disable intermediate caching for live video. Constructing a fresh `CIContext()` per renderer
/// (the old Prism pattern) wastes memory and prevents the GPU pipeline from fusing kernels.
///
/// Pass one `PRMRenderContext` to every `PRMFilterRenderer` and `PRMPreviewView` in a session.
///
/// ```swift
/// let context = PRMRenderContext()
/// let renderer = PRMBasicFilterRenderer(context: context, description: "Sepia") {
///     PRMSepiaFilter(intensity: 0.8)
/// }
/// ```
public struct PRMRenderContext: @unchecked Sendable {
    /// The shared Metal device.
    public let device: any MTLDevice

    /// The shared Metal command queue.
    public let commandQueue: any MTLCommandQueue

    /// The shared Core Image context, bound to ``commandQueue``.
    public let ciContext: CIContext

    /// Creates a new render context with a freshly allocated Metal device + command queue.
    ///
    /// - Parameter name: Debug name for the Core Image context (visible in Instruments).
    /// - Returns: A configured context, or `nil` if Metal is unavailable.
    public init?(name: String = "PRMRenderContext") {
        guard let device = MTLCreateSystemDefaultDevice() else {
            PRMLogger.filter.error("Metal device unavailable — cannot create PRMRenderContext")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            PRMLogger.filter.error("Failed to create Metal command queue")
            return nil
        }
        let ciContext = CIContext(
            mtlCommandQueue: queue,
            options: [
                .cacheIntermediates: false,
                .name: name,
            ]
        )
        self.device = device
        self.commandQueue = queue
        self.ciContext = ciContext
    }

    /// Creates a context wrapping caller-provided Metal resources.
    ///
    /// Use this when the preview view already owns a Metal device/queue and you want to share.
    public init(device: any MTLDevice, commandQueue: any MTLCommandQueue, name: String = "PRMRenderContext") {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                .cacheIntermediates: false,
                .name: name,
            ]
        )
    }
}
