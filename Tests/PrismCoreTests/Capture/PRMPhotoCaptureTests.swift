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
/// - Output property is `nil` for a session-based wrapper before any capture.
/// - Capturing without a photo output throws a typed error; AVFoundation errors keep their code.
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
    func `Session-based init has no output before any capture`() {
        // The session-based init resolves at each capture, so there's nothing to report
        // until the first one (a placeholder would hand out an output that delivers nothing).
        let capture = PRMPhotoCapture(session: PRMCameraSession())
        #expect(capture.output == nil)
    }

    @Test
    func `Capturing without a photo output throws instead of raising`() async {
        let capture = PRMPhotoCapture(session: PRMCameraSession())
        do {
            _ = try await capture.capturePhoto()
            Issue.record("Expected the capture to throw")
        } catch let error as PRMSessionError {
            guard case .photoCaptureFailed = error else {
                Issue.record("Unexpected PRMSessionError case: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    @Test
    func `An empty burst returns no photos`() async throws {
        let capture = PRMPhotoCapture(session: PRMCameraSession())
        #expect(try await capture.captureBurst(count: 0).isEmpty)
    }

    @Test
    func `AVFoundation errors keep their code`() {
        let hardware = NSError(domain: AVFoundationErrorDomain, code: -11872)
        guard case let .captureFailed(avError) = PRMPhotoCapture.sessionError(for: hardware) else {
            Issue.record("Expected captureFailed")
            return
        }
        #expect(avError.code.rawValue == -11872)
        let other = NSError(domain: NSCocoaErrorDomain, code: 4)
        guard case .photoCaptureFailed = PRMPhotoCapture.sessionError(for: other) else {
            Issue.record("Expected photoCaptureFailed for a non-AVFoundation error")
            return
        }
    }

    @Test
    func `Portrait requests follow what the output delivers`() {
        // A bare output delivers no depth or matte, so a Portrait capture must not request
        // them (AVFoundation raises when the output has delivery off).
        let output = AVCapturePhotoOutput()
        let portrait = PRMPhotoCapture.portraitSettings(from: PRMPhotoSettings(), output: output)
        #expect(portrait.depthDataDelivery == nil)
        #expect(portrait.portraitEffectsMatte == nil)
        #expect(portrait.embedsDepthDataInPhoto == nil)
    }

    @Test
    func `No manual bracket fires on an output or camera that can't take one`() {
        // Firing one anyway raises NSInvalidArgumentException (iOS 27 checks the active format),
        // so manual exposure falls back to regular settings. A bare output allows no bracket.
        let output = AVCapturePhotoOutput()
        #expect(PRMPhotoCapture.manualBracketBlocker(device: nil, output: output) != nil)
    }

    @Test
    func `A burst error carries the photos already captured`() {
        let error = PRMBurstInterruptedError(capturedPhotos: [], underlyingError: PRMSessionError.cancelled)
        #expect(error.capturedPhotos.isEmpty)
        #expect(error.underlyingError as? PRMSessionError == .cancelled)
        #expect(error.localizedDescription.contains("0 photos"))
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
    func `A photo smaller than asked for says so, with the known reason`() {
        let fortyEight = CMVideoDimensions(width: 8064, height: 6048)
        let twelve = CMVideoDimensions(width: 4032, height: 3024)
        #expect(PRMPhotoCapture.smallerThanRequestedText(twelve, requested: fortyEight, sizeLimit: "why") == " (asked for up to 8064x6048: why)")
        #expect(PRMPhotoCapture.smallerThanRequestedText(twelve, requested: fortyEight, sizeLimit: nil)
            == " (asked for up to 8064x6048: AVFoundation delivered a smaller size)")
        #expect(PRMPhotoCapture.smallerThanRequestedText(fortyEight, requested: fortyEight, sizeLimit: "why").isEmpty)
        #expect(PRMPhotoCapture.smallerThanRequestedText(twelve, requested: nil, sizeLimit: "why").isEmpty)
    }

    @Test
    func `The capture line says default size when no size is set`() {
        #expect(PRMPhotoCapture.sizeText(CMVideoDimensions(width: 0, height: 0)) == "default size")
        #expect(PRMPhotoCapture.sizeText(CMVideoDimensions(width: 8064, height: 6048)) == "up to 8064×6048")
    }

    @Test
    func `A codec the output doesn't offer falls back to the default`() {
        let output = AVCapturePhotoOutput()
        #expect(PRMPhotoSettings.availableCodec(nil, on: output) == nil)
        let offered = output.availablePhotoCodecTypes
        #expect(PRMPhotoSettings.availableCodec(.hevc, on: output) == (offered.contains(.hevc) ? .hevc : nil))
    }

    @Test
    func `Manual captures and 24MP without deferred delivery report why they're smaller`() {
        let output = AVCapturePhotoOutput()
        let settings = AVCapturePhotoSettings()
        #expect(PRMPhotoCapture.sizeLimit(of: settings, output: output, manualCapture: true) != nil)
        settings.maxPhotoDimensions = CMVideoDimensions(width: 5712, height: 4284)
        let twentyFour = PRMPhotoCapture.sizeLimit(of: settings, output: output, manualCapture: false)
        #expect(twentyFour?.contains("deferred") == true)
        settings.maxPhotoDimensions = CMVideoDimensions(width: 8064, height: 6048)
        #expect(PRMPhotoCapture.sizeLimit(of: settings, output: output, manualCapture: false) == nil)
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
