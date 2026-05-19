import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMFocusIndicatorViewTests {
    @Test
    func `Default alpha is 0`() {
        let view = PRMFocusIndicatorView()
        #expect(view.alpha == 0)
    }

    @Test
    func `show() positions and adds to parent`() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let view = PRMFocusIndicatorView()
        view.show(at: CGPoint(x: 100, y: 100), in: parent)
        #expect(view.superview === parent)
    }

    @Test
    func `hide() removes from parent`() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let view = PRMFocusIndicatorView()
        view.show(at: CGPoint(x: 100, y: 100), in: parent)
        view.hide()
        #expect(view.superview == nil)
    }
}
