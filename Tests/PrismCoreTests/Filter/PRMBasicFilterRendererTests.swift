import CoreMedia
import CoreVideo
import Testing
@testable import PrismCore

private func makeBGRAFormatDescription() -> CMFormatDescription? {
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCVPixelFormatType_32BGRA,
        width: 64,
        height: 64,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    return formatDescription
}

private func makePixelBuffer() -> CVPixelBuffer? {
    let attrs: NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attrs, &pb)
    return pb
}

struct PRMBasicFilterRendererTests {
    @Test
    func `Description is set`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        #expect(renderer.description == "Test")
    }

    @Test
    func `Starts unprepared`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        #expect(!renderer.isPrepared)
    }

    @Test
    func `Prepare succeeds for 32BGRA`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        let format = try #require(makeBGRAFormatDescription())
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        #expect(renderer.isPrepared)
        #expect(renderer.outputFormatDescription != nil)
    }

    @Test
    func `Reset releases resources`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        let format = try #require(makeBGRAFormatDescription())
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        renderer.reset()
        #expect(!renderer.isPrepared)
        #expect(renderer.outputFormatDescription == nil)
    }

    @Test
    func `Render returns a buffer after prepare`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        let format = try #require(makeBGRAFormatDescription())
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        let input = try #require(makePixelBuffer())
        let output = renderer.render(pixelBuffer: input)
        #expect(output != nil)
    }

    @Test
    func `Render returns nil when not prepared`() throws {
        let context = try #require(PRMRenderContext())
        let renderer = PRMBasicFilterRenderer(context: context, description: "Test") { PRMPassThroughFilter() }
        let input = try #require(makePixelBuffer())
        let output = renderer.render(pixelBuffer: input)
        #expect(output == nil)
    }
}
