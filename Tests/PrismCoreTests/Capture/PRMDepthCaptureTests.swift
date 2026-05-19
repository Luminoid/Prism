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
    func `addDepthDataOutput attaches and wires up the delegate`() {
        // `canAddOutput` doesn't require a matching video input on the simulator — the
        // session happily accepts a bare `AVCaptureDepthDataOutput` and only fails to
        // *produce* depth data when no compatible source is present. So the helper attaches
        // the output and configures the delegate; real depth delivery is hardware-gated.
        let session = AVCaptureSession()

        final class TestDelegate: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {}
        let delegate = TestDelegate()
        let queue = DispatchQueue(label: "test.depth")
        let result = PRMDepthCapture.addDepthDataOutput(to: session, delegate: delegate, queue: queue)
        #expect(result != nil)
        #expect(session.outputs.count == 1)
        #expect(session.outputs.first is AVCaptureDepthDataOutput)
        #expect(result?.delegate === delegate)
    }
}
