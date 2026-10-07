import CoreGraphics
import Testing
@testable import PrismCore

struct PRMMetadataRouterTests {
    @Test
    func `Published objects reach subscribers`() async {
        let router = PRMMetadataRouter()
        var iterator = router.detectedObjects().makeAsyncIterator()
        let face = PRMDetectedObject(kind: .face, bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), objectID: 3)
        router.publish([face])
        let delivered = await iterator.next()
        #expect(delivered == [face])
    }

    @Test
    func `Last focus-tracked object follows the latest batch`() {
        let router = PRMMetadataRouter()
        #expect(router.lastFocusTrackedObject == nil)
        let tracked = PRMDetectedObject(kind: .focusTracked, bounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        router.publish([PRMDetectedObject(kind: .face, bounds: .zero), tracked])
        #expect(router.lastFocusTrackedObject == tracked)
        router.publish([])
        #expect(router.lastFocusTrackedObject == nil)
    }
}
