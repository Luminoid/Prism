import CoreVideo
import Metal
import simd

/// Adds aligned frames into a linear, weighted sum on the GPU and normalizes it. See
/// `PRMNightMerge.metal`.
///
/// Holds one `rgba16Float` accumulator the size of the frames (about 100 MB at 12 MP). The sums
/// stay unnormalized until ``finish(into:)``: dividing per frame would push shadows into
/// half-float subnormals. Every call waits for its GPU work, so the frame's pixel buffer can be
/// released (back to the capture pool) as soon as it returns. Not thread-safe: call from one
/// queue.
final class PRMNightMerger {
    /// Mirrors `NightMergeUniforms` in the shader (`float3x3` columns pad to 16 bytes, like
    /// `simd_float3x3`).
    struct Uniforms {
        var warp: simd_float3x3
        var frameSize: SIMD2<Float>
        var smallScale: SIMD2<Float>
        var ghostLow: Float
        var ghostHigh: Float
        var transfer: UInt32
        var isReference: UInt32
    }

    enum Transfer: UInt32 {
        case sRGB = 0
        case bt709 = 1

        /// The frame's transfer function from its attachments; sRGB when untagged.
        init(of pixelBuffer: CVPixelBuffer) {
            let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
            if let value, CFEqual(value, kCVImageBufferTransferFunction_ITU_R_709_2) {
                self = .bt709
            } else {
                self = .sRGB
            }
        }
    }

    let width: Int
    let height: Int
    private let commandQueue: any MTLCommandQueue
    private let accumulatePipeline: any MTLRenderPipelineState
    private let normalizePipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var accumulator: (any MTLTexture)?
    private(set) var addedFrames = 0

    init?(device: any MTLDevice, commandQueue: any MTLCommandQueue, width: Int, height: Int) {
        guard width > 0, height > 0,
              let library = try? device.makeDefaultLibrary(bundle: .module),
              let vertex = library.makeFunction(name: "nightFullscreenVertex"),
              let accumulate = library.makeFunction(name: "nightAccumulateFragment"),
              let normalize = library.makeFunction(name: "nightNormalizeFragment")
        else {
            PRMLog.error(.capture, "Night merge: Metal shaders unavailable")
            return nil
        }
        let accumulateDescriptor = MTLRenderPipelineDescriptor()
        accumulateDescriptor.vertexFunction = vertex
        accumulateDescriptor.fragmentFunction = accumulate
        let attachment: MTLRenderPipelineColorAttachmentDescriptor = accumulateDescriptor.colorAttachments[0]
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

        let normalizeDescriptor = MTLRenderPipelineDescriptor()
        normalizeDescriptor.vertexFunction = vertex
        normalizeDescriptor.fragmentFunction = normalize
        normalizeDescriptor.colorAttachments[0].pixelFormat = .rgba16Float

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        guard let accumulatePipeline = try? device.makeRenderPipelineState(descriptor: accumulateDescriptor),
              let normalizePipeline = try? device.makeRenderPipelineState(descriptor: normalizeDescriptor),
              let cache,
              let accumulator = device.makeTexture(descriptor: textureDescriptor)
        else {
            PRMLog.error(.capture, "Night merge: couldn't set up the GPU pipeline for \(width)×\(height)")
            return nil
        }
        self.width = width
        self.height = height
        self.commandQueue = commandQueue
        self.accumulatePipeline = accumulatePipeline
        self.normalizePipeline = normalizePipeline
        textureCache = cache
        self.accumulator = accumulator
        accumulator.label = "Night accumulator"
    }

    /// Adds `frame` (BGRA, the merger's size) warped by `warp` (reference pixel to frame
    /// pixel, top-left origin). The first call clears the accumulator: pass the reference
    /// there, with `isReference`. Returns `false` when the GPU work failed.
    @discardableResult
    func add(
        frame: CVPixelBuffer,
        frameSmall: CVPixelBuffer,
        referenceSmall: CVPixelBuffer,
        warp: simd_float3x3,
        isReference: Bool,
        ghost: (low: Float, high: Float)
    ) -> Bool {
        guard let accumulator,
              CVPixelBufferGetWidth(frame) == width, CVPixelBufferGetHeight(frame) == height,
              let frameTexture = makeTexture(frame, format: .bgra8Unorm),
              let frameSmallTexture = makeTexture(frameSmall, format: .bgra8Unorm),
              let referenceSmallTexture = makeTexture(referenceSmall, format: .bgra8Unorm),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = accumulator
        pass.colorAttachments[0].loadAction = addedFrames == 0 ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let frameMetal = CVMetalTextureGetTexture(frameTexture),
              let frameSmallMetal = CVMetalTextureGetTexture(frameSmallTexture),
              let referenceSmallMetal = CVMetalTextureGetTexture(referenceSmallTexture)
        else { return false }

        var uniforms = Uniforms(
            warp: warp,
            frameSize: SIMD2(Float(width), Float(height)),
            smallScale: SIMD2(
                Float(CVPixelBufferGetWidth(frameSmall)) / Float(width),
                Float(CVPixelBufferGetHeight(frameSmall)) / Float(height)
            ),
            ghostLow: ghost.low,
            ghostHigh: ghost.high,
            transfer: Transfer(of: frame).rawValue,
            isReference: isReference ? 1 : 0
        )
        encoder.setRenderPipelineState(accumulatePipeline)
        encoder.setFragmentTexture(frameMetal, index: 0)
        encoder.setFragmentTexture(frameSmallMetal, index: 1)
        encoder.setFragmentTexture(referenceSmallMetal, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The CVMetalTextures (and the buffers under them) stay alive until here.
        withExtendedLifetime((frameTexture, frameSmallTexture, referenceSmallTexture)) {}
        guard commandBuffer.status == .completed else {
            PRMLog.error(.capture, "Night merge: GPU pass failed (status \(commandBuffer.status.rawValue))")
            return false
        }
        addedFrames += 1
        return true
    }

    /// Writes the normalized linear image into `output` (`64RGBAHalf`, IOSurface-backed, the
    /// merger's size) and frees the accumulator. Returns `false` when nothing was added or
    /// the GPU work failed.
    func finish(into output: CVPixelBuffer) -> Bool {
        guard addedFrames > 0, let accumulator,
              let outputTexture = makeTexture(output, format: .rgba16Float),
              let outputMetal = CVMetalTextureGetTexture(outputTexture),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputMetal
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(normalizePipeline)
        encoder.setFragmentTexture(accumulator, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(outputTexture) {}
        self.accumulator = nil
        return commandBuffer.status == .completed
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }

    // MARK: - Buffers

    /// An IOSurface-backed, Metal-compatible pixel buffer.
    static func makePixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        return buffer
    }
}
