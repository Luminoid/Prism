import AVFoundation
import Testing
@testable import PrismCore

struct PRMCameraSessionTests {
    @Test
    @PRMCameraActor
    func `Initialization yields a fresh session`() {
        let session = PRMCameraSession()
        #expect(session.configuration == nil)
        #expect(session.videoDevice == nil)
        #expect(!session.isRunning)
    }

    @Test
    func `makeDefaultMainActor is callable from any context`() {
        let session = PRMCameraSession.makeDefaultMainActor()
        // Just verify the factory works; we can't query actor-isolated state here.
        _ = session.session
    }
}
