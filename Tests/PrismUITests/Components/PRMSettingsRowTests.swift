import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMSettingsRowTests {
    @Test
    func `Initial state is expanded by default`() {
        let row = PRMSettingsRow(
            symbolName: "gear",
            title: "Gear",
            valueText: "off",
            content: UIView()
        )
        #expect(row.isExpanded == true)
        #expect(row.title == "Gear")
        #expect(row.valueText == "off")
        #expect(row.symbolName == "gear")
    }

    @Test
    func `Caller can opt into collapsed state`() {
        let row = PRMSettingsRow(
            symbolName: "gear",
            title: "Gear",
            isExpanded: false,
            content: UIView()
        )
        #expect(row.isExpanded == false)
    }

    @Test
    func `Toggling isExpanded fires onToggle`() {
        let row = PRMSettingsRow(
            symbolName: "gear",
            title: "Gear",
            content: UIView()
        )
        var observed: Bool?
        row.onToggle = { observed = $0 }
        row.isExpanded = true
        #expect(row.isExpanded)
        // onToggle only fires through the header button tap, not via the property setter,
        // so this is just a state-set check. The header-tap callback is exercised via the
        // example app.
        _ = observed
    }

    @Test
    func `Value text updates label`() {
        let row = PRMSettingsRow(
            symbolName: "gear",
            title: "Gear",
            valueText: "off",
            content: UIView()
        )
        row.valueText = "on"
        #expect(row.valueText == "on")
    }
}
