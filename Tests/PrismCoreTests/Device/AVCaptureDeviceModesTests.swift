import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Modes.swift`: the mode names and list text that unsupported-mode
/// errors are built from. The per-device support lists need a real camera.
struct AVCaptureDeviceModesTests {
    @Test
    func `Mode names read as words, not raw values`() {
        #expect(AVCaptureDevice.ExposureMode.prm_allCases.map(\.prm_name) == ["locked", "auto (one-shot)", "continuous auto", "custom"])
        #expect(AVCaptureDevice.WhiteBalanceMode.prm_allCases.map(\.prm_name) == ["locked", "auto (one-shot)", "continuous auto"])
        #expect(AVCaptureDevice.FocusMode.prm_allCases.map(\.prm_name) == ["locked", "auto (one-shot)", "continuous auto"])
    }

    @Test(arguments: [
        ([String](), "no modes"),
        (["locked"], "locked"),
        (["locked", "continuous auto"], "locked and continuous auto"),
        (["locked", "auto (one-shot)", "continuous auto"], "locked, auto (one-shot) and continuous auto"),
    ])
    func `Supported modes join into a sentence`(names: [String], expected: String) {
        #expect(AVCaptureDevice.prm_listText(names) == expected)
    }
}
