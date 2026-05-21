import MetalKit
import PrismCore

// MARK: - PRMPreviewView

/// Metal-accelerated camera preview view.
///
/// Renders ``PRMVideoFrame`` pixel buffers from the camera pipeline. Supports rotation and
/// mirroring, plus coordinate transforms for tap-to-focus.
///
/// **Threading model**: pixel buffers come from the filter pipeline's data-output queue;
/// the view buffers the latest under a small lock, and `MTKView` polls it on its own
/// `CADisplayLink` draw cycle. No per-frame Task hops to MainActor (a costly pattern in the
/// old design).
@MainActor
public final class PRMPreviewView: MTKView {
    // MARK: - Types

    public enum Rotation: CGFloat, Sendable {
        case rotate0 = 0
        case rotate90 = 90
        case rotate180 = 180
        case rotate270 = 270

        public init(angle: CGFloat) {
            let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            switch normalized {
            case 0: self = .rotate0
            case 90: self = .rotate90
            case 180: self = .rotate180
            case 270: self = .rotate270
            default: self = .rotate0
            }
        }
    }

    public enum ContentFit: Sendable {
        /// Scale to fill, cropping excess.
        case fill
        /// Scale to fit, letterboxing if needed.
        case fit
    }

    // MARK: - Public state (MainActor-isolated)

    /// Content fit mode. Defaults to `.fill`.
    public var contentFit: ContentFit = .fill {
        didSet { needsTransformRebuild = true }
    }

    /// Whether to horizontally mirror (front camera).
    public var mirroring: Bool = false {
        didSet { needsTransformRebuild = true }
    }

    /// Rotation to apply to the texture.
    public var rotation: Rotation = .rotate0 {
        didSet { needsTransformRebuild = true }
    }

    // MARK: - Thread-shared latest frame

    /// Lock-protected latest buffer (set from frame delivery queue, read from MainActor draw).
    private nonisolated(unsafe) var latestPixelBuffer: CVPixelBuffer?
    private nonisolated let bufferLock = NSLock()

    // MARK: - Metal pipeline

    private var renderPipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var sampler: MTLSamplerState?
    private var vertexCoordBuffer: MTLBuffer?
    private var textureCoordBuffer: MTLBuffer?

    // Cached transform state
    private var textureTransform: CGAffineTransform = .identity
    private var needsTransformRebuild = true
    private var lastTextureWidth = 0
    private var lastTextureHeight = 0
    private var lastBounds: CGRect = .zero

    // MARK: - Init

    public init(frame: CGRect = .zero, context: PRMRenderContext? = nil) {
        let device = context?.device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        configureView()
        configureMetal(commandQueue: context?.commandQueue)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("Use init(frame:context:) instead")
    }

    // MARK: - Setup

    private func configureView() {
        backgroundColor = .clear
        framebufferOnly = false
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        // Cap in-flight drawables at 2 (default is 3). At 60fps camera + 60Hz display the
        // queue tends to stay saturated, adding a 3rd buffered frame's worth of latency
        // (~50ms) between camera and screen. With 2 drawables that worst case drops to
        // ~33ms, and at 30fps there's still enough headroom to never starve the GPU.
        // Visible as: at 60fps preview, fast camera pans look one frame behind the device
        // motion. Saved video is unaffected — encoder uses its own path.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    }

    private func configureMetal(commandQueue: (any MTLCommandQueue)?) {
        guard let metalDevice = device else {
            PRMLogger.preview.error("Metal device not available")
            return
        }
        guard let library = try? metalDevice.makeDefaultLibrary(bundle: Bundle.module) else {
            PRMLogger.preview.error("Failed to create Metal library from Bundle.module")
            return
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexPassThrough")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentPassThrough")
        guard let pipelineState = try? metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            PRMLogger.preview.error("Failed to create render pipeline state")
            return
        }
        renderPipelineState = pipelineState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)

        self.commandQueue = commandQueue ?? metalDevice.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache)
        textureCache = cache
    }

    // MARK: - Frame intake

    /// Updates the latest pixel buffer. Safe to call from any queue.
    public nonisolated func update(_ pixelBuffer: CVPixelBuffer) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }

    // MARK: - Tap-to-focus

    /// Converts a view-space point to texture-space (0–1) accounting for rotation/mirroring.
    public func texturePoint(fromViewPoint point: CGPoint) -> CGPoint {
        let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        return normalized.applying(textureTransform)
    }

    /// Converts a texture-space (0–1) point to view space.
    public func viewPoint(fromTexturePoint point: CGPoint) -> CGPoint {
        let transformed = point.applying(textureTransform.inverted())
        return CGPoint(x: transformed.x * bounds.width, y: transformed.y * bounds.height)
    }

    // MARK: - Cleanup

    /// Flushes the Metal texture cache. Call on memory warnings or backgrounding.
    public func flushTextureCache() {
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    // MARK: - Drawing

    override public func draw(_ rect: CGRect) {
        bufferLock.lock()
        let pixelBuffer = latestPixelBuffer
        bufferLock.unlock()

        guard let pixelBuffer else { return }
        guard let renderPipelineState, let commandQueue, let sampler, let textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )
        guard let cvTexture = cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        if needsTransformRebuild
            || width != lastTextureWidth
            || height != lastTextureHeight
            || bounds != lastBounds {
            rebuildTransform(width: width, height: height)
            needsTransformRebuild = false
            lastTextureWidth = width
            lastTextureHeight = height
            lastBounds = bounds
        }

        guard let vertexCoordBuffer, let textureCoordBuffer else { return }
        guard let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setRenderPipelineState(renderPipelineState)
        encoder.setVertexBuffer(vertexCoordBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(textureCoordBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Transform

    private func rebuildTransform(width: Int, height: Int) {
        guard let metalDevice = device else { return }

        let drawableWidth = Float(drawableSize.width)
        let drawableHeight = Float(drawableSize.height)
        guard drawableWidth > 0, drawableHeight > 0 else { return }

        let textureWidth: Float
        let textureHeight: Float
        switch rotation {
        case .rotate0, .rotate180:
            textureWidth = Float(width)
            textureHeight = Float(height)
        case .rotate90, .rotate270:
            textureWidth = Float(height)
            textureHeight = Float(width)
        }
        guard textureWidth > 0, textureHeight > 0 else { return }

        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        switch contentFit {
        case .fill:
            if textureWidth / textureHeight > drawableWidth / drawableHeight {
                scaleX = textureWidth / textureHeight * drawableHeight / drawableWidth
                scaleY = 1.0
            } else {
                scaleX = 1.0
                scaleY = textureHeight / textureWidth * drawableWidth / drawableHeight
            }
        case .fit:
            if textureWidth / textureHeight > drawableWidth / drawableHeight {
                scaleX = 1.0
                scaleY = drawableWidth / drawableHeight * textureHeight / textureWidth
            } else {
                scaleX = drawableHeight / drawableWidth * textureWidth / textureHeight
                scaleY = 1.0
            }
        }
        if mirroring { scaleX *= -1.0 }

        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
            scaleX, -scaleY, 0.0, 1.0,
            -scaleX, scaleY, 0.0, 1.0,
            scaleX, scaleY, 0.0, 1.0,
        ]
        vertexCoordBuffer = metalDevice.makeBuffer(
            bytes: vertexData,
            length: vertexData.count * MemoryLayout<Float>.size,
            options: []
        )

        let textureCoords: [Float] = switch rotation {
        case .rotate0: [0, 1, 1, 1, 0, 0, 1, 0]
        case .rotate90: [1, 1, 1, 0, 0, 1, 0, 0]
        case .rotate180: [1, 0, 0, 0, 1, 1, 0, 1]
        case .rotate270: [0, 0, 0, 1, 1, 0, 1, 1]
        }
        textureCoordBuffer = metalDevice.makeBuffer(
            bytes: textureCoords,
            length: textureCoords.count * MemoryLayout<Float>.size,
            options: []
        )

        var transform = CGAffineTransform.identity
        if mirroring {
            transform = transform.concatenating(
                CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: 1, y: 0))
            )
        }
        switch rotation {
        case .rotate0:
            break
        case .rotate90:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: .pi / 2))
                .concatenating(CGAffineTransform(translationX: 1, y: 0))
        case .rotate180:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: .pi))
                .concatenating(CGAffineTransform(translationX: 1, y: 1))
        case .rotate270:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: 3 * .pi / 2))
                .concatenating(CGAffineTransform(translationX: 0, y: 1))
        }
        textureTransform = transform
    }
}
