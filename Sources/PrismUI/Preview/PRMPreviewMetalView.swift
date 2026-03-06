import MetalKit
import PrismCore

// MARK: - PRMPreviewMetalView

/// Metal-accelerated camera preview view.
///
/// Renders `CVPixelBuffer` frames from the camera pipeline with correct rotation and mirroring.
/// Supports tap-to-focus coordinate transforms between view and texture space.
///
/// Thread-safe: `pixelBuffer`, `rotation`, and `mirroring` can be set from any queue.
public final class PRMPreviewMetalView: MTKView, @unchecked Sendable {
    // MARK: - Rotation

    /// Rotation applied to the preview texture.
    public enum Rotation: Int, Sendable {
        case rotate0Degrees
        case rotate90Degrees
        case rotate180Degrees
        case rotate270Degrees
    }

    // MARK: - Public Properties

    /// Whether the preview is horizontally mirrored (front camera).
    ///
    /// Thread-safe: can be set from any queue.
    public nonisolated(unsafe) var mirroring = false {
        didSet {
            syncQueue.sync { internalMirroring = mirroring }
        }
    }

    /// The rotation applied to the preview.
    ///
    /// Thread-safe: can be set from any queue.
    public nonisolated(unsafe) var rotation: Rotation = .rotate0Degrees {
        didSet {
            syncQueue.sync { internalRotation = rotation }
        }
    }

    /// The current pixel buffer to display. Set from the filter pipeline's data output queue.
    ///
    /// Thread-safe: can be set from any queue.
    public nonisolated(unsafe) var pixelBuffer: CVPixelBuffer? {
        didSet {
            syncQueue.sync { internalPixelBuffer = pixelBuffer }
        }
    }

    // MARK: - Private State

    private let syncQueue = DispatchQueue(
        label: "com.luminoid.Prism.PreviewViewSync",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    // Thread-local copies (accessed only inside syncQueue or draw)
    private nonisolated(unsafe) var internalPixelBuffer: CVPixelBuffer?
    private nonisolated(unsafe) var internalMirroring = false
    private nonisolated(unsafe) var internalRotation: Rotation = .rotate0Degrees

    // Metal pipeline
    private var renderPipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var sampler: MTLSamplerState?
    private var vertexCoordBuffer: MTLBuffer?
    private var textureCoordBuffer: MTLBuffer?

    /// Transform for coordinate mapping (view ↔ texture)
    private var textureTranform: CGAffineTransform?

    // Last known state for recalculation
    private var lastTextureMirroring = false
    private var lastTextureRotation: Rotation = .rotate0Degrees
    private var lastTextureWidth = 0
    private var lastTextureHeight = 0
    private var lastBounds = CGRect.zero

    // MARK: - Initialization

    public init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        configureMetal()
        configureView()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("Use init(frame:) instead")
    }

    // MARK: - Setup

    private func configureMetal() {
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
            PRMLogger.preview.error("Failed to create Metal render pipeline state")
            return
        }
        renderPipelineState = pipelineState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)

        commandQueue = metalDevice.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache)
        textureCache = cache
    }

    private func configureView() {
        #if canImport(UIKit)
            backgroundColor = .clear
        #endif
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
    }

    // MARK: - Coordinate Transforms

    /// Converts a point from view coordinates to texture coordinates.
    ///
    /// Use this for tap-to-focus: convert the tap location to a texture-space point
    /// that accounts for rotation and mirroring.
    ///
    /// - Parameter point: A point in view coordinates.
    /// - Returns: The corresponding point in texture coordinates, or the input point if no transform is available.
    public func texturePoint(fromViewPoint point: CGPoint) -> CGPoint {
        guard let transform = textureTranform else { return point }
        let normalizedPoint = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height,
        )
        return normalizedPoint.applying(transform)
    }

    /// Converts a point from texture coordinates to view coordinates.
    ///
    /// - Parameter point: A point in texture coordinates.
    /// - Returns: The corresponding point in view coordinates.
    public func viewPoint(fromTexturePoint point: CGPoint) -> CGPoint {
        guard let transform = textureTranform?.inverted() else { return point }
        let transformedPoint = point.applying(transform)
        return CGPoint(
            x: transformedPoint.x * bounds.width,
            y: transformedPoint.y * bounds.height,
        )
    }

    /// Requests a new frame to be drawn.
    ///
    /// Thread-safe: can be called from any queue (dispatches drawing to the main actor).
    /// Call this from the filter pipeline's `onFrame` callback.
    public nonisolated func requestDraw() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                self.draw()
            }
        }
    }

    // MARK: - Drawing

    override public func draw(_ rect: CGRect) {
        // Snapshot state from sync queue
        var currentPixelBuffer: CVPixelBuffer?
        var currentMirroring = false
        var currentRotation: Rotation = .rotate0Degrees

        syncQueue.sync {
            currentPixelBuffer = internalPixelBuffer
            currentMirroring = internalMirroring
            currentRotation = internalRotation
        }

        guard let pixelBuffer = currentPixelBuffer else { return }
        guard let renderPipelineState, let commandQueue, let sampler else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0 else { return }

        // Create Metal texture from pixel buffer
        guard let textureCache else { return }
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
            &cvTextureOut,
        )

        guard let cvTexture = cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        // Recalculate transform if anything changed
        if width != lastTextureWidth
            || height != lastTextureHeight
            || bounds != lastBounds
            || currentMirroring != lastTextureMirroring
            || currentRotation != lastTextureRotation {
            setupTransform(
                width: width,
                height: height,
                mirroring: currentMirroring,
                rotation: currentRotation,
            )
            lastTextureWidth = width
            lastTextureHeight = height
            lastBounds = bounds
            lastTextureMirroring = currentMirroring
            lastTextureRotation = currentRotation
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

    // MARK: - Transform Setup

    private func setupTransform(width: Int, height: Int, mirroring: Bool, rotation: Rotation) {
        guard let metalDevice = device else { return }

        // Calculate aspect-fill scaling
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0

        let drawableWidth = Float(drawableSize.width)
        let drawableHeight = Float(drawableSize.height)

        guard drawableWidth > 0, drawableHeight > 0 else { return }

        let textureWidth: Float
        let textureHeight: Float

        switch rotation {
        case .rotate0Degrees, .rotate180Degrees:
            textureWidth = Float(width)
            textureHeight = Float(height)
        case .rotate90Degrees, .rotate270Degrees:
            textureWidth = Float(height)
            textureHeight = Float(width)
        }

        guard textureWidth > 0, textureHeight > 0 else { return }

        // Aspect fill
        if textureWidth / textureHeight > drawableWidth / drawableHeight {
            scaleX = textureWidth / textureHeight * drawableHeight / drawableWidth
            scaleY = 1.0
        } else {
            scaleX = 1.0
            scaleY = textureHeight / textureWidth * drawableWidth / drawableHeight
        }

        if mirroring {
            scaleX *= -1.0
        }

        // Vertex coordinates (clip space)
        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
            scaleX, -scaleY, 0.0, 1.0,
            -scaleX, scaleY, 0.0, 1.0,
            scaleX, scaleY, 0.0, 1.0,
        ]
        vertexCoordBuffer = metalDevice.makeBuffer(
            bytes: vertexData,
            length: vertexData.count * MemoryLayout<Float>.size,
            options: [],
        )

        // Texture coordinates vary by rotation
        let textureCoords: [Float] = switch rotation {
        case .rotate0Degrees:
            [0, 1, 1, 1, 0, 0, 1, 0]
        case .rotate90Degrees:
            [1, 1, 1, 0, 0, 1, 0, 0]
        case .rotate180Degrees:
            [1, 0, 0, 0, 1, 1, 0, 1]
        case .rotate270Degrees:
            [0, 0, 0, 1, 1, 0, 1, 1]
        }
        textureCoordBuffer = metalDevice.makeBuffer(
            bytes: textureCoords,
            length: textureCoords.count * MemoryLayout<Float>.size,
            options: [],
        )

        // Build CGAffineTransform for coordinate mapping
        // Maps from normalized view coordinates to normalized texture coordinates
        var transform = CGAffineTransform.identity

        // Apply mirroring
        if mirroring {
            transform = transform.concatenating(
                CGAffineTransform(scaleX: -1, y: 1).concatenating(
                    CGAffineTransform(translationX: 1, y: 0),
                ),
            )
        }

        // Apply rotation
        switch rotation {
        case .rotate0Degrees:
            break
        case .rotate90Degrees:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: .pi / 2))
                .concatenating(CGAffineTransform(translationX: 1, y: 0))
        case .rotate180Degrees:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: .pi))
                .concatenating(CGAffineTransform(translationX: 1, y: 1))
        case .rotate270Degrees:
            transform = transform
                .concatenating(CGAffineTransform(rotationAngle: 3 * .pi / 2))
                .concatenating(CGAffineTransform(translationX: 0, y: 1))
        }

        textureTranform = transform
    }

    // MARK: - Cleanup

    /// Flushes the Metal texture cache. Call on memory warnings or when going to background.
    public func flushTextureCache() {
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }
}
