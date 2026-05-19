import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Torch.swift`.
///
/// `AVCaptureDevice` instances can't be constructed standalone (no public init), and the
/// simulator returns `nil` from `AVCaptureDevice.default(for:)`. So device-touching code
/// paths are exercised by the example app and the manual test plan. Here we test the
/// `PRMTorchMode` value type that the API takes — equality, exhaustiveness, and the level
/// associated value semantics.
struct AVCaptureDeviceTorchTests {
    typealias TorchMode = AVCaptureDevice.PRMTorchMode

    @Test
    func `PRMTorchMode equality`() {
        #expect(TorchMode.off == TorchMode.off)
        #expect(TorchMode.auto == TorchMode.auto)
        #expect(TorchMode.on(level: 0.5) == TorchMode.on(level: 0.5))
        #expect(TorchMode.on(level: 0.5) != TorchMode.on(level: 0.6))
        #expect(TorchMode.off != TorchMode.auto)
        #expect(TorchMode.off != TorchMode.on(level: 1.0))
    }

    @Test
    func `PRMTorchMode is Sendable`() async {
        // Compile-time: detached Task captures must be Sendable.
        let result = await Task.detached { TorchMode.on(level: 0.75) }.value
        #expect(result == .on(level: 0.75))
    }

    @Test
    func `Level associated value is plain Float (0 and 1 both valid as inputs)`() {
        // The extension clamps internally; here we just confirm the input range type.
        let zero: TorchMode = .on(level: 0.0)
        let one: TorchMode = .on(level: 1.0)
        let huge: TorchMode = .on(level: 999) // input — clamping happens inside prm_setTorch
        if case let .on(level) = zero { #expect(level == 0.0) }
        if case let .on(level) = one { #expect(level == 1.0) }
        if case let .on(level) = huge { #expect(level == 999) }
    }
}
