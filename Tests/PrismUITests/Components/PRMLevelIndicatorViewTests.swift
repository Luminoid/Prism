import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMLevelIndicatorViewTests {
    @Test
    func defaults() {
        let view = PRMLevelIndicatorView()
        #expect(!view.isActive)
        #expect(!view.isLevel)
        #expect(view.levelThreshold == 1.0)
    }

    @Test
    func `Setting isActive does not crash on simulator`() {
        let view = PRMLevelIndicatorView()
        view.isActive = true
        view.isActive = false
    }
}
