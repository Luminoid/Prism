import CoreImage
import CoreMedia
import CoreVideo
import Synchronization
import Testing
@testable import PrismCore

// MARK: - PRMBasicFilterRendererTests

@Suite("PRMBasicFilterRenderer")
struct PRMBasicFilterRendererTests {
    // MARK: - Helpers

    private func makeBGRAFormatDescription(width: Int32 = 64, height: Int32 = 64) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription,
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    private func makeTestPixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer,
        )
        return pixelBuffer
    }

    private func makePassthroughRenderer() -> PRMBasicFilterRenderer {
        PRMBasicFilterRenderer(description: "Passthrough") { MockFilter() }
    }

    // MARK: - Initialization

    @Test("Description is set from init")
    func descriptionFromInit() {
        let renderer = PRMBasicFilterRenderer(description: "Test") { MockFilter() }
        #expect(renderer.description == "Test")
    }

    @Test("Starts unprepared")
    func startsUnprepared() {
        let renderer = makePassthroughRenderer()
        #expect(!renderer.isPrepared)
        #expect(renderer.outputFormatDescription == nil)
        #expect(renderer.inputFormatDescription == nil)
    }

    // MARK: - Lifecycle

    @Test("Prepare sets isPrepared to true")
    func prepareSetsPrepared() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = makePassthroughRenderer()

        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)

        #expect(renderer.isPrepared)
        #expect(renderer.inputFormatDescription != nil)
        #expect(renderer.outputFormatDescription != nil)
    }

    @Test("Reset clears prepared state")
    func resetClearsPrepared() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = makePassthroughRenderer()

        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        #expect(renderer.isPrepared)

        renderer.reset()
        #expect(!renderer.isPrepared)
        #expect(renderer.inputFormatDescription == nil)
        #expect(renderer.outputFormatDescription == nil)
    }

    // MARK: - Rendering

    @Test("Render returns nil when not prepared")
    func renderBeforePrepare() throws {
        let renderer = makePassthroughRenderer()
        let buffer = try #require(makeTestPixelBuffer())
        let result = renderer.render(pixelBuffer: buffer)
        #expect(result == nil)
    }

    @Test("Render returns pixel buffer when prepared")
    func renderWhenPrepared() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = makePassthroughRenderer()
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)

        let buffer = try #require(makeTestPixelBuffer())
        let result = renderer.render(pixelBuffer: buffer)
        #expect(result != nil)
    }

    @Test("Render returns nil after reset")
    func renderAfterReset() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = makePassthroughRenderer()
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        renderer.reset()

        let buffer = try #require(makeTestPixelBuffer())
        let result = renderer.render(pixelBuffer: buffer)
        #expect(result == nil)
    }

    @Test("Re-prepare after reset works")
    func rePrepareAfterReset() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = makePassthroughRenderer()

        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        renderer.reset()
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)

        #expect(renderer.isPrepared)
        let buffer = try #require(makeTestPixelBuffer())
        let result = renderer.render(pixelBuffer: buffer)
        #expect(result != nil)
    }

    @Test("Render returns nil when filter returns nil")
    func renderWithFailingFilter() throws {
        let format = try #require(makeBGRAFormatDescription())
        let renderer = PRMBasicFilterRenderer(description: "Failing") {
            let filter = MockFilter()
            filter.shouldReturnNil = true
            return filter
        }
        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)

        let buffer = try #require(makeTestPixelBuffer())
        let result = renderer.render(pixelBuffer: buffer)
        #expect(result == nil)
    }

    @Test("Factory closure is called on prepare")
    func factoryCalledOnPrepare() throws {
        let format = try #require(makeBGRAFormatDescription())
        let factoryCallCount = Mutex(0)
        let renderer = PRMBasicFilterRenderer(description: "Counter") {
            factoryCallCount.withLock { $0 += 1 }
            return MockFilter()
        }

        renderer.prepare(with: format, outputRetainedBufferCountHint: 3)
        #expect(factoryCallCount.withLock { $0 } == 1)
    }
}
