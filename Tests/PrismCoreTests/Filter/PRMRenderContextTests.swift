import Testing
@testable import PrismCore

struct PRMRenderContextTests {
    @Test
    func `Default init succeeds on iOS simulator`() {
        let context = PRMRenderContext()
        #expect(context != nil)
    }

    @Test
    func `Context exposes Metal device + queue + CIContext`() throws {
        let context = try #require(PRMRenderContext())
        // Just verify access doesn't crash and resources exist.
        _ = context.device
        _ = context.commandQueue
        _ = context.ciContext
    }
}
