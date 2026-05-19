import AVFoundation
import Testing
@testable import PrismCore

/// `PRMCamera` is the MainActor facade. Configuring a real session requires a physical
/// camera device, which isn't available on the simulator — `AVCaptureDevice.default(for:)`
/// returns nil, so `configure(_:)` would throw `.noVideoDevice`. We test the parts that
/// don't depend on hardware: lifecycle of the facade itself, stream semantics, and the
/// documented asymmetry between stateStream and errorStream/interruptionStream.
@MainActor
struct PRMCameraTests {
    @Test
    func `Default-init produces a camera with no device snapshot yet`() {
        let camera = PRMCamera()
        #expect(camera.device == nil)
        #expect(!camera.state.isRunning)
    }

    @Test
    func `Default state has documented defaults`() {
        let camera = PRMCamera()
        #expect(camera.state.zoomFactor == 1.0)
        #expect(camera.state.torchMode == .off)
        #expect(camera.state.exposureBias == 0)
        #expect(camera.state.frameRate == nil)
        #expect(!camera.state.isInterrupted)
    }

    @Test
    func `State stream emits an initial snapshot`() async {
        let camera = PRMCamera()
        var iterator = camera.stateStream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        #expect(first?.isRunning == false)
    }

    @Test
    func `State stream supports multiple concurrent subscribers`() async {
        let camera = PRMCamera()
        // Both subscribers should get the initial state.
        async let firstA = camera.stateStream().first { _ in true }
        async let firstB = camera.stateStream().first { _ in true }
        let (a, b) = await (firstA, firstB)
        #expect(a != nil)
        #expect(b != nil)
        // They observe the same logical state value.
        #expect(a?.zoomFactor == b?.zoomFactor)
    }

    @Test
    func `Error stream does NOT yield on subscribe`() async {
        // Documented asymmetry: errorStream emits only on actual errors, not on subscribe.
        // We give the stream 50ms to produce a value via a sentinel; if it never does, the
        // sentinel stays false.
        let camera = PRMCamera()
        let received = StreamProbe<PRMSessionError>()
        let task = Task {
            var iterator = camera.errorStream().makeAsyncIterator()
            if let value = await iterator.next() {
                await received.record(value)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        let captured = await received.captured
        #expect(captured == nil)
    }

    @Test
    func `Interruption stream does NOT yield on subscribe`() async {
        let camera = PRMCamera()
        let received = StreamProbe<Bool>()
        let task = Task {
            var iterator = camera.interruptionStream().makeAsyncIterator()
            if let value = await iterator.next() {
                await received.record(value)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        let captured = await received.captured
        #expect(captured == nil)
    }

    @Test
    func `Stream cancellation removes the continuation`() async {
        // After a stream is cancelled, the onTermination handler fires and the camera's
        // internal continuation dictionary entry is removed. We can't read the dict
        // directly (it's private), but cancelling and re-subscribing should still yield
        // the initial state, proving the camera isn't stuck.
        let camera = PRMCamera()

        let task = Task { @MainActor in
            var iterator = camera.stateStream().makeAsyncIterator()
            _ = await iterator.next()
        }
        task.cancel()
        _ = await task.value

        // Second subscription should still work — yields initial state.
        var iterator = camera.stateStream().makeAsyncIterator()
        let value = await iterator.next()
        #expect(value != nil)
    }

    @Test
    func `Session property exposes the underlying PRMCameraSession`() {
        let camera = PRMCamera()
        // The session is allocated lazily during init via makeDefaultMainActor().
        let session = camera.session
        // Same instance on repeated access (it's a `let`).
        #expect(camera.session === session)
    }

    @Test
    func `Custom session injection`() {
        // Verifies the `init(session:)` overload accepts and retains a custom session.
        let custom = PRMCameraSession.makeDefaultMainActor()
        let camera = PRMCamera(session: custom)
        #expect(camera.session === custom)
    }
}

/// Holds the first value an AsyncStream yields, if any, so a test can check after a timeout
/// whether the stream produced anything. Implemented as an actor for Sendable correctness
/// when the recording task crosses isolation boundaries.
private actor StreamProbe<Element: Sendable> {
    private(set) var captured: Element?

    func record(_ value: Element) {
        if captured == nil { captured = value }
    }
}
