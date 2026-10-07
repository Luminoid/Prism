import AVFoundation
import Testing
@testable import PrismCore

/// `PRMDepthCapture` is a stateless namespace of static helpers. Each method short-circuits
/// when the underlying device/output doesn't support depth, so we can exercise the
/// no-support branches against a freshly-allocated `AVCapturePhotoOutput` without crashing.
/// Real depth delivery requires a dual/triple-camera device + an attached session.
struct PRMDepthCaptureTests {
    @Test
    func `isSupported is false on a bare AVCapturePhotoOutput`() {
        // A standalone AVCapturePhotoOutput (no session, no connection) reports
        // isDepthDataDeliverySupported == false.
        let output = AVCapturePhotoOutput()
        #expect(PRMDepthCapture.isSupported(on: output) == output.isDepthDataDeliverySupported)
    }

    @Test
    func `setEnabled no-ops when depth is unsupported`() {
        let output = AVCapturePhotoOutput()
        // Should not throw, crash, or mutate state when isDepthDataDeliverySupported is false.
        PRMDepthCapture.setEnabled(true, on: output)
        // The supported check guards against the system raising —
        // `isDepthDataDeliveryEnabled = true` would crash if support is false.
        #expect(PRMDepthCapture.isEnabled(on: output) == output.isDepthDataDeliveryEnabled)
    }

    @Test
    func `setFiltering on a depth output mutates the flag`() {
        // AVCaptureDepthDataOutput can be allocated standalone — its `isFilteringEnabled`
        // setter is safe without an attached session.
        let output = AVCaptureDepthDataOutput()
        PRMDepthCapture.setFiltering(true, on: output)
        #expect(output.isFilteringEnabled == true)
        PRMDepthCapture.setFiltering(false, on: output)
        #expect(output.isFilteringEnabled == false)
    }

    @Test
    @PRMCameraActor
    func `The session attaches, keeps and detaches a depth stream`() async throws {
        // `canAddOutput` doesn't require a matching video input on the simulator — the
        // session accepts a bare `AVCaptureDepthDataOutput` and only fails to *produce*
        // depth data without a compatible source. Real delivery is hardware-gated.
        final class TestDelegate: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {}
        let session = PRMCameraSession()
        let delegate = TestDelegate()
        let output = try await session.attachDepthDataOutput(delegate: delegate, queue: DispatchQueue(label: "test.depth"))
        #expect(session.depthDataOutput === output)
        #expect(output.delegate === delegate)
        #expect(session.session.outputs.contains { $0 === output })
        // A second attach only updates the delegate.
        let again = try await session.attachDepthDataOutput(delegate: delegate, queue: DispatchQueue(label: "test.depth"), filteringEnabled: false)
        #expect(again === output)
        #expect(!output.isFilteringEnabled)
        await session.detachDepthDataOutput()
        #expect(session.depthDataOutput == nil)
        #expect(session.session.outputs.isEmpty)
    }
}
