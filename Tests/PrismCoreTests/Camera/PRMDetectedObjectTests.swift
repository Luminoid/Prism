import AVFoundation
import Testing
@testable import PrismCore

struct PRMDetectedObjectTests {
    @Test
    func `Negative identifiers mean none`() {
        #expect(PRMDetectedObject.identifier(-1) == nil)
        #expect(PRMDetectedObject.identifier(0) == 0)
        #expect(PRMDetectedObject.identifier(42) == 42)
    }

    @Test
    func `Kinds map from metadata types`() {
        #expect(PRMDetectedObject.Kind(.face) == .face)
        #expect(PRMDetectedObject.Kind(.humanBody) == .humanBody)
        #expect(PRMDetectedObject.Kind(.humanFullBody) == .humanFullBody)
        #expect(PRMDetectedObject.Kind(.catBody) == .catBody)
        #expect(PRMDetectedObject.Kind(.dogBody) == .dogBody)
        #expect(PRMDetectedObject.Kind(.salientObject) == .salientObject)
        #expect(PRMDetectedObject.Kind(.qr) == .other(AVMetadataObject.ObjectType.qr.rawValue))
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Pet head kinds map on iOS 26`() {
        guard #available(iOS 26.0, *) else { return }
        #expect(PRMDetectedObject.Kind(.catHead) == .catHead)
        #expect(PRMDetectedObject.Kind(.dogHead) == .dogHead)
    }

    @Test(.enabled(if: OSAvailability.isIOS27))
    func `The focus-tracked kind maps on iOS 27`() {
        guard #available(iOS 27.0, *) else { return }
        #expect(PRMDetectedObject.Kind(.focusTrackedObject) == .focusTracked)
    }

    @Test
    func `Center is the middle of the bounds`() {
        let object = PRMDetectedObject(kind: .face, bounds: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2))
        #expect(abs(object.center.x - 0.3) < 1e-9)
        #expect(abs(object.center.y - 0.5) < 1e-9)
    }
}
