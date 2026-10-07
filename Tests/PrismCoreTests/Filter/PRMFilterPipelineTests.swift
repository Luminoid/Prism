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
    func `The latency window reports average and maximum once per interval`() {
        var window = LatencyWindow()
        #expect(window.add(0.030, now: 10, interval: 5) == nil)
        #expect(window.add(0.050, now: 12, interval: 5) == nil)
        let summary = window.add(0.040, now: 15, interval: 5)
        #expect(summary?.count == 3)
        #expect(abs((summary?.average ?? 0) - 0.040) < 1e-9)
        #expect(summary?.maximum == 0.050)
        #expect(summary?.span == 5)
        // A fresh window starts after the flush.
        #expect(window.add(0.5, now: 16, interval: 5) == nil)
    }

    @Test
    func `A gap longer than the interval starts the latency window over`() {
        var window = LatencyWindow()
        #expect(window.add(0.030, now: 10, interval: 5) == nil)
        // Ten minutes in the background: the old sample doesn't join the next summary.
        #expect(window.add(0.040, now: 610, interval: 5) == nil)
        let summary = window.add(0.050, now: 615, interval: 5)
        #expect(summary?.count == 2)
        #expect(summary?.span == 5)
        #expect(summary?.maximum == 0.050)
    }

    @Test
    func `Frame stream can be created without crashing`() {
        let pipeline = PRMFilterPipeline()
        let stream = pipeline.frameStream()
        // Just verify type is correct.
        _ = stream
    }
}
