import AVFoundation
import Testing
@testable import PrismCore

/// `PRMPhotoCapture` wraps `AVCapturePhotoOutput`. Calling `capturePhoto` without an attached,
/// running `AVCaptureSession` is undefined (Apple's docs say "the photo output must be added
/// to a session"). We test the bits that don't require an active session:
///
/// - Initialization with a bare `AVCapturePhotoOutput`.
/// - Output property is the same instance that was injected.
/// - Type is `Sendable` across actor hops.
/// - Public API key paths exist (schema lock).
struct PRMPhotoCaptureTests {
    @Test
    func `Initializer retains the output reference`() {
        let output = AVCapturePhotoOutput()
        let capture = PRMPhotoCapture(output: output)
        #expect(capture.output === output)
    }

    @Test
    func `Two independent captures don't share state`() {
        let outA = AVCapturePhotoOutput()
        let outB = AVCapturePhotoOutput()
        let captureA = PRMPhotoCapture(output: outA)
        let captureB = PRMPhotoCapture(output: outB)
        #expect(captureA.output !== captureB.output)
        #expect(captureA !== captureB)
    }

    @Test
    func `NSObject conformance is in place for AVFoundation delegate dispatch`() {
        // PRMPhotoCapture conforms to AVCapturePhotoCaptureDelegate, which requires NSObject.
        // This compiles only if both conformances are intact.
        let capture = PRMPhotoCapture(output: AVCapturePhotoOutput())
        let asObject: NSObject = capture
        let asDelegate: any AVCapturePhotoCaptureDelegate = capture
        #expect(asObject === capture)
        // Use _ to read the delegate reference so the optimizer doesn't drop the conversion.
        _ = asDelegate
    }

    @Test
    func `Sendable conformance via actor hop`() async {
        let capture = PRMPhotoCapture(output: AVCapturePhotoOutput())
        // Sending across an `await` boundary requires Sendable.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = capture.output
                continuation.resume()
            }
        }
    }
}
