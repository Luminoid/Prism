import CoreMedia
import Testing
@testable import PrismCore

// MARK: - MockRenderer

final class MockRenderer: PRMCameraFilterRenderer, @unchecked Sendable {
    let description: String
    var isPrepared = false
    var outputFormatDescription: CMFormatDescription?
    var inputFormatDescription: CMFormatDescription?

    var prepareCallCount = 0
    var resetCallCount = 0
    var renderCallCount = 0

    init(description: String = "MockRenderer") {
        self.description = description
    }

    func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        prepareCallCount += 1
        isPrepared = true
        inputFormatDescription = formatDescription
    }

    func reset() {
        resetCallCount += 1
        isPrepared = false
        inputFormatDescription = nil
        outputFormatDescription = nil
    }

    func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        renderCallCount += 1
        return pixelBuffer // pass-through
    }
}

// MARK: - PRMFilterPipelineTests

@Suite("PRMFilterPipeline")
struct PRMFilterPipelineTests {
    // MARK: - Initialization

    @Test("Starts with rendering disabled")
    func startsDisabled() {
        let pipeline = PRMFilterPipeline()
        #expect(!pipeline.isRenderingEnabled)
    }

    @Test("Starts with no active renderer")
    func startsWithNoRenderer() {
        let pipeline = PRMFilterPipeline()
        #expect(pipeline.activeRenderer == nil)
    }

    @Test("Starts with no format description")
    func startsWithNoFormat() {
        let pipeline = PRMFilterPipeline()
        #expect(pipeline.currentFormatDescription == nil)
    }

    // MARK: - Renderer Switching

    @Test("Setting active renderer resets previous renderer")
    func switchResetsOld() {
        let pipeline = PRMFilterPipeline()
        let rendererA = MockRenderer(description: "A")
        let rendererB = MockRenderer(description: "B")

        pipeline.activeRenderer = rendererA
        pipeline.activeRenderer = rendererB

        #expect(rendererA.resetCallCount == 1)
    }

    @Test("Setting active renderer to nil resets current")
    func clearResetsRenderer() {
        let pipeline = PRMFilterPipeline()
        let renderer = MockRenderer()

        pipeline.activeRenderer = renderer
        pipeline.activeRenderer = nil

        #expect(renderer.resetCallCount == 1)
    }

    // MARK: - Rendering Toggle

    @Test("Rendering can be enabled and disabled")
    func renderingToggle() {
        let pipeline = PRMFilterPipeline()
        pipeline.isRenderingEnabled = true
        #expect(pipeline.isRenderingEnabled)
        pipeline.isRenderingEnabled = false
        #expect(!pipeline.isRenderingEnabled)
    }

    // MARK: - Frame Callback

    @Test("onFrame closure can be set")
    func onFrameSetup() {
        let pipeline = PRMFilterPipeline()
        var called = false
        pipeline.onFrame = { _, _ in
            called = true
        }
        // Just verifying setup — actual callback requires AVCaptureOutput
        #expect(!called)
    }
}
