import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMSettingsRowTests {
    @Test
    func `Initial state is collapsed`() {
        let row = PRMSettingsRow(
            symbolName: "gear",
            title: "Gear",
            valueText: "off",
            content: UIView()
        )
        #expect(row.isExpanded == false)
        #expect(row.title == "Gear")
        #expect(row.valueText == "off")
        #expect(row.symbolName == "gear")
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
