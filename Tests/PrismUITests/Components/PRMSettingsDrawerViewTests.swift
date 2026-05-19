import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMSettingsDrawerViewTests {
    @Test
    func `Drawer starts closed`() {
        let drawer = PRMSettingsDrawerView(title: "Camera")
        #expect(!drawer.isOpen)
    }

    @Test
    func `setOpen flips state`() {
        let drawer = PRMSettingsDrawerView(title: "Camera")
        drawer.setOpen(true, animated: false)
        #expect(drawer.isOpen)
        drawer.setOpen(false, animated: false)
        #expect(!drawer.isOpen)
    }

    @Test
    func `Append and clear sections`() {
        let drawer = PRMSettingsDrawerView()
        let row = PRMSettingsRow(symbolName: "gear", title: "EV", content: UISlider())
        drawer.appendSection(title: "Exposure", rows: [row])
        drawer.clear()
        // Smoke: clear() must not crash and may be called repeatedly.
        drawer.clear()
        #expect(true)
    }
}
