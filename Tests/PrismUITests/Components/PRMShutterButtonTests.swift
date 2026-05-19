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
}
