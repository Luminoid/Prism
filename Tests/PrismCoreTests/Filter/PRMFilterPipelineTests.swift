import Testing
@testable import PrismCore

struct PRMFilterPipelineTests {
    @Test
    func `Pipeline is disabled by default`() {
        let pipeline = PRMFilterPipeline()
        #expect(!pipeline.isEnabled)
        #expect(pipeline.activeRenderer == nil)
    }

    @Test
    func `Setting active renderer resets the old one`() throws {
        let context = try #require(PRMRenderContext())
        let pipeline = PRMFilterPipeline()
        let r1 = PRMBasicFilterRenderer(context: context, description: "A") { PRMPassThroughFilter() }
        let r2 = PRMBasicFilterRenderer(context: context, description: "B") { PRMPassThroughFilter() }
        pipeline.activeRenderer = r1
        pipeline.activeRenderer = r2
        #expect(pipeline.activeRenderer === r2)
    }

    @Test
    func `Frame stream can be created without crashing`() {
        let pipeline = PRMFilterPipeline()
        let stream = pipeline.frameStream()
        // Just verify type is correct.
        _ = stream
    }
}
