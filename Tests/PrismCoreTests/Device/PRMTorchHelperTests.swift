import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMTorchHelper")
struct PRMTorchHelperTests {
    // MARK: - TorchMode Enum

    @Test("TorchMode on has associated level")
    func torchModeOn() {
        let mode = PRMTorchHelper.TorchMode.on(level: 0.5)
        #expect(mode == .on(level: 0.5))
    }

    @Test("TorchMode off is equatable")
    func torchModeOff() {
        #expect(PRMTorchHelper.TorchMode.off == .off)
    }

    @Test("TorchMode auto is equatable")
    func torchModeAuto() {
        #expect(PRMTorchHelper.TorchMode.auto == .auto)
    }

    @Test("TorchMode on with different levels are not equal")
    func torchModeLevelInequality() {
        #expect(PRMTorchHelper.TorchMode.on(level: 0.3) != .on(level: 0.7))
    }

    @Test("TorchMode different cases are not equal")
    func torchModeCaseInequality() {
        #expect(PRMTorchHelper.TorchMode.on(level: 1.0) != .off)
        #expect(PRMTorchHelper.TorchMode.off != .auto)
    }

    // MARK: - Query Signatures

    @Test("Has torch query method exists")
    func hasTorchSignature() {
        let _: (AVCaptureDevice) -> Bool = PRMTorchHelper.hasTorch(on:)
    }

    @Test("Is torch available query method exists")
    func isTorchAvailableSignature() {
        let _: (AVCaptureDevice) -> Bool = PRMTorchHelper.isTorchAvailable(on:)
    }

    @Test("Current torch level query method exists")
    func currentTorchLevelSignature() {
        let _: (AVCaptureDevice) -> Float = PRMTorchHelper.currentTorchLevel(on:)
    }

    @Test("Is torch active query method exists")
    func isTorchActiveSignature() {
        let _: (AVCaptureDevice) -> Bool = PRMTorchHelper.isTorchActive(on:)
    }

    @Test("Set torch mode method exists with correct signature")
    func setTorchModeSignature() {
        let _: (PRMTorchHelper.TorchMode, AVCaptureDevice) throws -> Void = PRMTorchHelper.setTorchMode(_:on:)
    }
}
