import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureConnection+Stabilization.swift`.
///
/// `AVCaptureConnection` instances exist only in attached sessions — can't be tested
/// standalone. Lock the public surface and the documented stabilization mode coverage.
struct AVCaptureConnectionStabilizationTests {
    @Test
    func `Public method signature compiles`() {
        // Signature-lock: prm_setStabilization takes an AVCaptureVideoStabilizationMode.
        let setStab: (AVCaptureConnection) -> (AVCaptureVideoStabilizationMode) -> Void =
            { connection in connection.prm_setStabilization }
        _ = setStab
        #expect(true)
    }

    @Test
    func `Stabilization modes documented as supported are all reachable`() {
        // These are the AVFoundation modes Prism passes through verbatim. The helper itself
        // doesn't filter — it just no-ops when isVideoStabilizationSupported is false.
        let modes: [AVCaptureVideoStabilizationMode] = [
            .off,
            .standard,
            .cinematic,
            .cinematicExtended,
            .auto,
        ]
        #expect(!modes.isEmpty)
        // Equatable conformance is required to use these in switch statements.
        #expect(AVCaptureVideoStabilizationMode.off == .off)
        #expect(AVCaptureVideoStabilizationMode.off != .standard)
    }
}
