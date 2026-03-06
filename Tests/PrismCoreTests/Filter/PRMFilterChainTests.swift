import CoreImage
import CoreMedia
import CoreVideo
import Testing
@testable import PrismCore

@Suite("PRMFilterChain")
struct PRMFilterChainTests {
    // MARK: - Helpers

    private func makeBGRAFormatDescription(width: Int32 = 640, height: Int32 = 480) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription,
        )
        return formatDescription
    }

    private func makeTestPixelBuffer(width: Int = 640, height: Int = 480) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer,
        )
        return pixelBuffer
    }

    // MARK: - Mock Filter

    private final class PassthroughFilter: PRMCameraFilter, @unchecked Sendable {
        func render(image: CIImage) -> CIImage? {
            image
        }
    }

    private final class NilFilter: PRMCameraFilter, @unchecked Sendable {
        func render(image: CIImage) -> CIImage? {
            nil
        }
    }

    // MARK: - Initialization

    @Test("Description is set from init")
    func descriptionSet() {
        let chain = PRMFilterChain(description: "Test Chain")
        #expect(chain.description == "Test Chain")
    }

    @Test("Starts with empty filter list")
    func startsEmpty() {
        let chain = PRMFilterChain(description: "Empty")
        #expect(chain.filterCount == 0)
        #expect(chain.filters.isEmpty)
    }

    @Test("Can be initialized with filters")
    func initWithFilters() {
        let chain = PRMFilterChain(description: "Two", filters: [
            .init(filter: PassthroughFilter()),
            .init(filter: PassthroughFilter(), intensity: 0.5),
        ])
        #expect(chain.filterCount == 2)
    }

    // MARK: - Mutation

    @Test("Append adds a filter")
    func appendFilter() {
        let chain = PRMFilterChain(description: "Test")
        chain.append(PassthroughFilter())
        #expect(chain.filterCount == 1)
        chain.append(PassthroughFilter(), intensity: 0.5)
        #expect(chain.filterCount == 2)
    }

    @Test("Remove at valid index removes filter")
    func removeAtValidIndex() {
        let chain = PRMFilterChain(description: "Test", filters: [
            .init(filter: PassthroughFilter()),
            .init(filter: PassthroughFilter()),
        ])
        chain.remove(at: 0)
        #expect(chain.filterCount == 1)
    }

    @Test("Remove at invalid index is safe")
    func removeAtInvalidIndex() {
        let chain = PRMFilterChain(description: "Test")
        chain.remove(at: -1)
        chain.remove(at: 100)
        #expect(chain.filterCount == 0)
    }

    @Test("Remove all clears filters")
    func removeAllFilters() {
        let chain = PRMFilterChain(description: "Test", filters: [
            .init(filter: PassthroughFilter()),
            .init(filter: PassthroughFilter()),
        ])
        chain.removeAll()
        #expect(chain.filterCount == 0)
    }

    // MARK: - FilterEntry

    @Test("FilterEntry clamps intensity to 0-1 range")
    func filterEntryClamp() {
        let low = PRMFilterChain.FilterEntry(filter: PassthroughFilter(), intensity: -0.5)
        #expect(low.intensity == 0.0)

        let high = PRMFilterChain.FilterEntry(filter: PassthroughFilter(), intensity: 2.0)
        #expect(high.intensity == 1.0)

        let normal = PRMFilterChain.FilterEntry(filter: PassthroughFilter(), intensity: 0.7)
        #expect(normal.intensity == 0.7)
    }

    @Test("FilterEntry defaults to intensity 1.0")
    func filterEntryDefaultIntensity() {
        let entry = PRMFilterChain.FilterEntry(filter: PassthroughFilter())
        #expect(entry.intensity == 1.0)
    }

    // MARK: - Lifecycle

    @Test("Starts unprepared")
    func startsUnprepared() {
        let chain = PRMFilterChain(description: "Test")
        #expect(!chain.isPrepared)
    }

    @Test("Prepare sets isPrepared to true")
    func prepareSetsPrepared() throws {
        let chain = PRMFilterChain(description: "Test")
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        #expect(chain.isPrepared)
    }

    @Test("Reset clears prepared state")
    func resetClearsPrepared() throws {
        let chain = PRMFilterChain(description: "Test")
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        chain.reset()
        #expect(!chain.isPrepared)
    }

    @Test("Render returns nil when not prepared")
    func renderNilWhenNotPrepared() throws {
        let chain = PRMFilterChain(description: "Test")
        let buffer = try #require(makeTestPixelBuffer())
        #expect(chain.render(pixelBuffer: buffer) == nil)
    }

    // MARK: - Rendering

    @Test("Empty chain returns a pixel buffer (pass-through)")
    func emptyChainPassthrough() throws {
        let chain = PRMFilterChain(description: "Empty")
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        let input = try #require(makeTestPixelBuffer())
        let output = chain.render(pixelBuffer: input)
        // Empty chain returns the input buffer directly
        #expect(output != nil)
    }

    @Test("Single filter chain renders successfully")
    func singleFilterChain() throws {
        let chain = PRMFilterChain(description: "Single", filters: [
            .init(filter: PassthroughFilter()),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        let input = try #require(makeTestPixelBuffer())
        let output = chain.render(pixelBuffer: input)
        #expect(output != nil)
    }

    @Test("Multi-filter chain renders successfully")
    func multiFilterChain() throws {
        let chain = PRMFilterChain(description: "Multi", filters: [
            .init(filter: PassthroughFilter()),
            .init(filter: PassthroughFilter()),
            .init(filter: PassthroughFilter()),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        let input = try #require(makeTestPixelBuffer())
        let output = chain.render(pixelBuffer: input)
        #expect(output != nil)
    }

    @Test("Chain continues when a filter returns nil")
    func chainContinuesOnNil() throws {
        let chain = PRMFilterChain(description: "WithNil", filters: [
            .init(filter: PassthroughFilter()),
            .init(filter: NilFilter()),
            .init(filter: PassthroughFilter()),
        ])
        let format = try #require(makeBGRAFormatDescription())
        chain.prepare(with: format, outputRetainedBufferCountHint: 3)
        let input = try #require(makeTestPixelBuffer())
        let output = chain.render(pixelBuffer: input)
        #expect(output != nil)
    }
}
