import MetalKit
import PrismCore
import UIKit

// MARK: - PRMPreviewView

/// Metal-accelerated camera preview view.
///
/// Renders `PRMVideoFrame` pixel buffers from the camera pipeline. Supports rotation and
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
    /// Half-extent of the drawn quad in normalized device coordinates (before mirroring):
    /// above 1 the texture overflows the view (`.fill` crop), below 1 it's letterboxed (`.fit`).
    private var contentScale = CGSize(width: 1, height: 1)
    private var needsTransformRebuild = true
    /// The buffer the last frame drew; an unchanged buffer and layout skip the redraw.
    private var lastDrawnBuffer: CVPixelBuffer?
    /// Per-instance `PRMLog.once` key, so two previews don't re-arm each other's warning.
    private let textureLogKey = PRMLog.instanceKey("preview.texture")
    private var lastTextureWidth = 0
    private var lastTextureHeight = 0
    private var lastBounds: CGRect = .zero

    // MARK: - Init

    public init(frame: CGRect = .zero, context: PRMRenderContext? = nil) {
        let device = context?.device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        configureView()
        configureMetal(commandQueue: context?.commandQueue)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        PRMLog.resetOnce(textureLogKey)
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
            PRMLog.error(.preview, "Metal device not available; the preview stays blank")
            return
        }
        let library: any MTLLibrary
        do {
            library = try metalDevice.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            PRMLog.error(.preview, "Failed to create Metal library from Bundle.module; the preview stays blank", error: error)
            return
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexPassThrough")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentPassThrough")
        do {
            renderPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            PRMLog.error(.preview, "Failed to create render pipeline state; the preview stays blank", error: error)
            return
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)

        self.commandQueue = commandQueue ?? metalDevice.makeCommandQueue()

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache)
        if status != kCVReturnSuccess || cache == nil {
            PRMLog.error(.preview, "CVMetalTextureCacheCreate failed (CVReturn \(status)); the preview stays blank")
        }
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

    /// Converts a view-space point to texture space (`0...1` across the pixel buffer, origin
    /// top-left), undoing the content fit, mirroring and rotation the preview draws with.
    ///
    /// With `.fit`, taps in the letterbox land outside `0...1`; clamp before use. Texture
    /// space equals the capture device's point-of-interest space only when the video
    /// connection delivers unrotated (landscape) buffers; with a rotated connection, map the
    /// point back through that rotation first.
    public func texturePoint(fromViewPoint point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        return Self.texturePoint(fromNormalizedViewPoint: normalized, rotation: rotation, mirroring: mirroring, contentScale: contentScale)
    }

    /// Converts a texture-space point (`0...1`, origin top-left) to view space. Inverse of
    /// ``texturePoint(fromViewPoint:)``.
    public func viewPoint(fromTexturePoint point: CGPoint) -> CGPoint {
        let normalized = Self.normalizedViewPoint(fromTexturePoint: point, rotation: rotation, mirroring: mirroring, contentScale: contentScale)
        return CGPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }

    /// Pure mapping behind ``texturePoint(fromViewPoint:)``, derived from the quad's vertex
    /// and texture-coordinate tables (`u` runs across the buffer's width, `v` down its height).
    nonisolated static func texturePoint(
        fromNormalizedViewPoint point: CGPoint,
        rotation: Rotation,
        mirroring: Bool,
        contentScale: CGSize
    ) -> CGPoint {
        var x = 0.5 + (point.x - 0.5) / max(contentScale.width, .ulpOfOne)
        let y = 0.5 + (point.y - 0.5) / max(contentScale.height, .ulpOfOne)
        if mirroring { x = 1 - x }
        return switch rotation {
        case .rotate0: CGPoint(x: x, y: y)
        case .rotate90: CGPoint(x: y, y: 1 - x)
        case .rotate180: CGPoint(x: 1 - x, y: 1 - y)
        case .rotate270: CGPoint(x: 1 - y, y: x)
        }
    }

    /// Inverse of ``texturePoint(fromNormalizedViewPoint:rotation:mirroring:contentScale:)``.
    nonisolated static func normalizedViewPoint(
        fromTexturePoint point: CGPoint,
        rotation: Rotation,
        mirroring: Bool,
        contentScale: CGSize
    ) -> CGPoint {
        let unrotated = switch rotation {
        case .rotate0: CGPoint(x: point.x, y: point.y)
        case .rotate90: CGPoint(x: 1 - point.y, y: point.x)
        case .rotate180: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .rotate270: CGPoint(x: point.y, y: 1 - point.x)
        }
        let x = mirroring ? 1 - unrotated.x : unrotated.x
        return CGPoint(
            x: 0.5 + (x - 0.5) * contentScale.width,
            y: 0.5 + (unrotated.y - 0.5) * contentScale.height
        )
    }

    // MARK: - Cleanup

    /// Flushes the Metal texture cache. Runs on memory warnings by itself; call it when
    /// backgrounding too.
    public func flushTextureCache() {
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    @objc private func handleMemoryWarning() {
        flushTextureCache()
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

        let layoutChanged = needsTransformRebuild
            || width != lastTextureWidth
            || height != lastTextureHeight
            || bounds != lastBounds
        // The display link ticks at 60 Hz whether or not a frame arrived (and keeps ticking
        // while the session is stopped). The last drawable stays on screen, so an unchanged
        // buffer and layout need no new one.
        if !layoutChanged, pixelBuffer === lastDrawnBuffer { return }

        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
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
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            // Runs on every display-link tick, so one line per failure episode.
            PRMLog.once(
                textureLogKey,
                .error,
                .preview,
                """
                Texture creation failed (CVReturn \(status), pixel format \(PRMLog.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))), \
                \(width)x\(height)); the preview needs BGRA frames
                """
            )
            return
        }
        PRMLog.resetOnce(textureLogKey)

        if layoutChanged {
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

        // The texture cache recycles a texture's backing once the CVMetalTexture is
        // released, so keep it (and the buffer under it) alive until the GPU has read it.
        nonisolated(unsafe) let inFlight = (cvTexture, pixelBuffer)
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(inFlight) {}
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawnBuffer = pixelBuffer
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
        contentScale = CGSize(width: CGFloat(scaleX), height: CGFloat(scaleY))
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
    }
}
