import Testing
@testable import PrismUI

@MainActor
struct PRMShutterButtonTests {
    @Test
    func `Default mode is photo`() {
        let button = PRMShutterButton()
        #expect(button.mode == .photo)
    }

    @Test
    func `setMode changes mode`() {
        let button = PRMShutterButton()
        button.setMode(.recording, animated: false)
        #expect(button.mode == .recording)
        button.setMode(.recordingActive, animated: false)
        #expect(button.mode == .recordingActive)
        button.setMode(.photo, animated: false)
        #expect(button.mode == .photo)
    }

    @Test
    func `Intrinsic content size matches buttonSize`() {
        let button = PRMShutterButton()
        #expect(button.intrinsicContentSize.width == 76)
        button.buttonSize = 60
        #expect(button.intrinsicContentSize.width == 60)
    }

    @Test
    func `VoiceOver label follows the mode`() {
        let button = PRMShutterButton()
        #expect(button.accessibilityLabel == "Capture")
        button.setMode(.recording, animated: false)
        #expect(button.accessibilityLabel == "Start recording")
        button.setMode(.recordingActive, animated: false)
        #expect(button.accessibilityLabel == "Stop recording")
    }

    @Test
    func `Press-and-hold is offered as VoiceOver actions`() throws {
        let button = PRMShutterButton()
        #expect(button.accessibilityCustomActions == nil)
        var began = 0
        var ended = 0
        button.onLongPressBegan = { began += 1 }
        button.onLongPressEnded = { ended += 1 }
        let start = button.accessibilityCustomActions?.first
        #expect(start?.name == "Start video recording")
        _ = try start?.actionHandler?(#require(start))
        #expect(began == 1)
        let stop = button.accessibilityCustomActions?.first
        #expect(stop?.name == "Stop video recording")
        _ = try stop?.actionHandler?(#require(stop))
        #expect(ended == 1)
    }
}
