import CoreImage
import CoreMedia
import CoreVideo
import Testing
@testable import PrismCore

// MARK: - Test helpers

private func makeBGRAFormatDescription(width: Int32 = 64, height: Int32 = 64) -> CMFormatDescription? {
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCVPixelFormatType_32BGRA,
        width: width,
        height: height,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    return formatDescription
}

private func makeRedPixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
    let attrs: NSDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
    ]
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs,
        &pixelBuffer
    )
    guard let pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    // 32BGRA in memory: B, G, R, A. Fill with bright red (255, 0, 0).
    for y in 0 ..< height {
        let rowStart = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0 ..< width {
            let pixel = rowStart.advanced(by: x * 4)
            pixel[0] = 0 // B
            pixel[1] = 0 // G
            pixel[2] = 255 // R
            pixel[3] = 255 // A
        }
    }
    return pixelBuffer
}

private func samplePixel(_ pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
    return (pixel[0], pixel[1], pixel[2], pixel[3])
}

// MARK: - Tests

struct PRMFilterChainTests {
    private struct PassthroughFilter: PRMFilter {
        func render(_ image: CIImage) -> CIImage {
            image
        }
    }

    private struct ZeroOutFilter: PRMFilter {
        /// Replaces the input with solid black.
        func render(_ image: CIImage) -> CIImage {
            CIImage(color: CIColor.black).cropped(to: image.extent)
        }
    }

    // MARK: - Construction

    @Test
    func `Initializes with description`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test")
        #expect(chain.description == "test")
    }

    @Test
    func `Starts with the provided entries`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test", entries: [
            .init(filter: PassthroughFilter()),
        ])
        #expect(chain.count == 1)
    }

    @Test
    func `Append, remove, removeAll, move`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test")
        chain.append(PassthroughFilter())
        chain.append(PassthroughFilter(), intensity: 0.5)
        #expect(chain.count == 2)
        chain.move(from: 0, to: 1)
        chain.remove(at: 0)
        #expect(chain.count == 1)
        chain.removeAll()
        #expect(chain.isEmpty)
    }

    @Test
    func `Intensity clamped to 0...1`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test")
        chain.append(PassthroughFilter(), intensity: 5.0)
        chain.append(PassthroughFilter(), intensity: -1.0)
        #expect(chain.entries[0].intensity == 1.0)
        #expect(chain.entries[1].intensity == 0.0)
    }

    // MARK: - Prepare / reset

    @Test
    func `Prepare succeeds for 32BGRA`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test")
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        #expect(chain.isPrepared)
        chain.reset()
        #expect(!chain.isPrepared)
    }

    // MARK: - Critical: intensity-blend correctness

    /// Verifies the bug fix: with intensity = 0, the chain returns the previous step unchanged;
    /// with intensity = 1, the chain returns the filtered output; intermediates lerp.
    @Test
    func `Intensity = 0 returns previous step unchanged`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test", entries: [
            .init(filter: ZeroOutFilter(), intensity: 0.0),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 2)
        let input = try #require(makeRedPixelBuffer())
        let output = try #require(chain.render(pixelBuffer: input))

        let pixel = try #require(samplePixel(output, x: 32, y: 32))
        // Should remain red because intensity = 0 means skip the ZeroOut filter.
        #expect(pixel.r > 250)
        #expect(pixel.g < 5)
        #expect(pixel.b < 5)
    }

    @Test
    func `Intensity = 1 fully applies filter`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test", entries: [
            .init(filter: ZeroOutFilter(), intensity: 1.0),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 2)
        let input = try #require(makeRedPixelBuffer())
        let output = try #require(chain.render(pixelBuffer: input))

        let pixel = try #require(samplePixel(output, x: 32, y: 32))
        // Should be black because ZeroOut filter at full intensity produced solid black.
        #expect(pixel.r < 10)
        #expect(pixel.g < 10)
        #expect(pixel.b < 10)
    }

    @Test
    func `Intensity = 0.5 produces a mid-gray (~127)`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test", entries: [
            .init(filter: ZeroOutFilter(), intensity: 0.5),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 2)
        let input = try #require(makeRedPixelBuffer())
        let output = try #require(chain.render(pixelBuffer: input))

        let pixel = try #require(samplePixel(output, x: 32, y: 32))
        // With the fix, red lerps toward black at 0.5. In sRGB-space the midpoint between
        // (255,0,0) and (0,0,0) appears around 188 due to gamma encoding. Either way, red is
        // clearly attenuated relative to the input and green/blue stay near zero.
        #expect(pixel.r > 80 && pixel.r < 250)
        #expect(pixel.g < 30)
        #expect(pixel.b < 30)
    }

    @Test
    func `Empty chain returns the input unchanged`() throws {
        let context = try #require(PRMRenderContext())
        let chain = PRMFilterChain(context: context, description: "test")
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 2)
        let input = try #require(makeRedPixelBuffer())
        let output = try #require(chain.render(pixelBuffer: input))
        // Same buffer reference because the chain shortcuts when empty.
        #expect(output === input)
    }
}
