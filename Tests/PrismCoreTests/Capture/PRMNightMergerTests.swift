import CoreImage
import simd
import Testing
@testable import PrismCore

/// `PRMNightMerger` on the GPU with synthetic frames: averaging cuts noise, a moving subject
/// is left out, and the output is linear.
struct PRMNightMergerTests {
    private let width = 64
    private let height = 48

    @Test
    func `A flat frame comes out as its linear value`() throws {
        let context = try #require(PRMRenderContext())
        let merger = try #require(PRMNightMerger(device: context.device, commandQueue: context.commandQueue, width: width, height: height))
        let frame = try #require(NightTestImages.bgraBuffer(width: width, height: height) { _, _ in (128, 128, 128) })
        let small = try #require(downscale(frame, context: context))
        #expect(merger.add(frame: frame, frameSmall: small, referenceSmall: small, warp: matrix_identity_float3x3, isReference: true, ghost: (0.1, 0.45)))
        let output = try #require(PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_64RGBAHalf))
        #expect(merger.finish(into: output))
        let pixel = NightTestImages.halfPixel(output, x: 32, y: 24)
        #expect(abs(pixel.x - NightTestImages.srgbToLinear(128.0 / 255)) < 0.003)
        #expect(pixel.w == 1)
    }

    @Test
    func `Merging sixteen noisy frames cuts the noise variance about sixteen times`() throws {
        let context = try #require(PRMRenderContext())
        let merger = try #require(PRMNightMerger(device: context.device, commandQueue: context.commandQueue, width: width, height: height))
        var generator = SeededGenerator(seed: 7)
        var frames: [CVPixelBuffer] = []
        for _ in 0 ..< 16 {
            try frames.append(#require(noisyFrame(level: 128, spread: 20, generator: &generator)))
        }
        let referenceSmall = try #require(downscale(frames[0], context: context))
        for (index, frame) in frames.enumerated() {
            let small = try #require(downscale(frame, context: context))
            // Ghost rejection off: the noise must average, not be rejected.
            #expect(merger.add(frame: frame, frameSmall: small, referenceSmall: referenceSmall, warp: matrix_identity_float3x3, isReference: index == 0, ghost: (10, 20)))
        }
        let output = try #require(PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_64RGBAHalf))
        #expect(merger.finish(into: output))

        let single = try #require(noisyFrame(level: 128, spread: 20, generator: &generator))
        let singleVariance = variance(of: (0 ..< width * height).map { index in
            NightTestImages.srgbToLinear(Float(redByte(single, x: index % width, y: index / width)) / 255)
        })
        let mergedVariance = variance(of: (0 ..< width * height).map { index in
            NightTestImages.halfPixel(output, x: index % width, y: index / width).x
        })
        #expect(mergedVariance < singleVariance / 8)
    }

    @Test
    func `A subject that appears in one frame is left out`() throws {
        let context = try #require(PRMRenderContext())
        let merger = try #require(PRMNightMerger(device: context.device, commandQueue: context.commandQueue, width: width, height: height))
        let background = try #require(NightTestImages.bgraBuffer(width: width, height: height) { _, _ in (60, 60, 60) })
        let withSquare = try #require(NightTestImages.bgraBuffer(width: width, height: height) { x, y in
            (16 ..< 32).contains(x) && (16 ..< 32).contains(y) ? (250, 250, 250) : (60, 60, 60)
        })
        let referenceSmall = try #require(downscale(background, context: context))
        let squareSmall = try #require(downscale(withSquare, context: context))
        #expect(merger.add(frame: background, frameSmall: referenceSmall, referenceSmall: referenceSmall, warp: matrix_identity_float3x3, isReference: true, ghost: (0.1, 0.45)))
        for _ in 0 ..< 3 {
            #expect(merger.add(frame: background, frameSmall: referenceSmall, referenceSmall: referenceSmall, warp: matrix_identity_float3x3, isReference: false, ghost: (0.1, 0.45)))
        }
        #expect(merger.add(frame: withSquare, frameSmall: squareSmall, referenceSmall: referenceSmall, warp: matrix_identity_float3x3, isReference: false, ghost: (0.1, 0.45)))
        let output = try #require(PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_64RGBAHalf))
        #expect(merger.finish(into: output))
        let backgroundLinear = NightTestImages.srgbToLinear(60.0 / 255)
        #expect(abs(NightTestImages.halfPixel(output, x: 24, y: 24).x - backgroundLinear) < backgroundLinear * 0.1)
    }

    @Test
    func `Pixels warped from outside the frame get no weight`() throws {
        let context = try #require(PRMRenderContext())
        let merger = try #require(PRMNightMerger(device: context.device, commandQueue: context.commandQueue, width: width, height: height))
        let dark = try #require(NightTestImages.bgraBuffer(width: width, height: height) { _, _ in (40, 40, 40) })
        let bright = try #require(NightTestImages.bgraBuffer(width: width, height: height) { _, _ in (200, 200, 200) })
        let small = try #require(downscale(dark, context: context))
        #expect(merger.add(frame: dark, frameSmall: small, referenceSmall: small, warp: matrix_identity_float3x3, isReference: true, ghost: (10, 20)))
        // Shifted 40 px right: the left 40 columns of the reference look up x < 0.
        let shift = simd_float3x3(rows: [SIMD3(1, 0, -40), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
        #expect(merger.add(frame: bright, frameSmall: small, referenceSmall: small, warp: shift, isReference: false, ghost: (10, 20)))
        let output = try #require(PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_64RGBAHalf))
        #expect(merger.finish(into: output))
        // Still the plain value there: weight 1 from the reference alone.
        #expect(abs(NightTestImages.halfPixel(output, x: 5, y: 24).x - NightTestImages.srgbToLinear(40.0 / 255)) < 0.003)
    }

    @Test
    func `BT.709 frames are linearized with BT.709`() throws {
        let frame = try #require(NightTestImages.bgraBuffer(width: 4, height: 4) { _, _ in (128, 128, 128) })
        #expect(PRMNightMerger.Transfer(of: frame) == .sRGB)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        #expect(PRMNightMerger.Transfer(of: frame) == .bt709)
    }

    // MARK: - Helpers

    private func downscale(_ frame: CVPixelBuffer, context: PRMRenderContext) -> CVPixelBuffer? {
        PRMNightRegistration(fullWidth: width, fullHeight: height, context: context.ciContext).makeSmall(frame)
    }

    private func noisyFrame(level: Int, spread: Int, generator: inout SeededGenerator) -> CVPixelBuffer? {
        var values: [UInt8] = []
        for _ in 0 ..< width * height {
            values.append(UInt8(clamping: level + Int.random(in: -spread ... spread, using: &generator)))
        }
        return NightTestImages.bgraBuffer(width: width, height: height) { [width] x, y in
            let value = values[y * width + x]
            return (value, value, value)
        }
    }

    private func redByte(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        return (base + y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)[x * 4 + 2]
    }

    private func variance(of values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
    }
}
