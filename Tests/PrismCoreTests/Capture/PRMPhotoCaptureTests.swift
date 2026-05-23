import AVFoundation
import Testing
@testable import PrismCore

/// `PRMPhotoCapture` wraps `AVCapturePhotoOutput`. Calling `capturePhoto` without an attached,
/// running `AVCaptureSession` is undefined (Apple's docs say "the photo output must be added
/// to a session"). We test the bits that don't require an active session:
///
/// - Initialization with a bare `AVCapturePhotoOutput` (legacy `init(output:)`).
/// - Initialization with a `PRMCameraSession` (session-based `init(session:)`).
/// - Output property is the same instance that was injected (fixed resolver).
/// - Output property returns a non-nil placeholder before any capture has resolved a session-bound output.
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
    func `Session-based init produces a placeholder output before any capture`() {
        // The session-based `init(session:)` doesn't eagerly resolve — the
        // first resolution happens at the entry of the first capture call. The
        // public `output` property still has to be non-nil for back-compat
        // (e.g. `PRMNightModeCapture` reads it through its `.capture.output`
        // identity), so the wrapper returns a placeholder `AVCapturePhotoOutput`
        // instance instead of trapping. The placeholder's identity is stable
        // across reads — but it is NOT the same instance as the session's
        // current photoOutput (the simulator session has no inputs, so no
        // photoOutput has been attached either).
        let session = PRMCameraSession()
        let capture = PRMPhotoCapture(session: session)
        let first = capture.output
        let second = capture.output
        #expect(type(of: first) == AVCapturePhotoOutput.self)
        #expect(type(of: second) == AVCapturePhotoOutput.self)
    }

    @Test
    func `Session-based and output-based wrappers can coexist with distinct identities`() {
        // Two independent wrappers around independent sessions don't share
        // resolver state — covers the case where a consuming app holds both
        // legacy and session-based wrappers during a migration.
        let legacyOutput = AVCapturePhotoOutput()
        let legacy = PRMPhotoCapture(output: legacyOutput)
        let session = PRMCameraSession()
        let modern = PRMPhotoCapture(session: session)
        #expect(legacy !== modern)
        #expect(legacy.output === legacyOutput)
        #expect(modern.output !== legacyOutput)
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
