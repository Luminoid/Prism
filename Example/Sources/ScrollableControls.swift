import UIKit

// MARK: - ControlScrollView

/// UIScrollView subclass that allows scrolling over UIControl subviews.
/// By default, `touchesShouldCancel(in:)` returns `false` for UIControls,
/// preventing the scroll view from ever cancelling their touch to begin panning.
class ControlScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }
}

// MARK: - ScrollableSegmentedControl

/// Since iOS 13, UISegmentedControl has a built-in pan gesture for swiping
/// between segments. This steals horizontal pan from the parent scroll view,
/// making it nearly impossible to scroll. Overriding `gestureRecognizerShouldBegin`
/// to return `true` lets the scroll view's pan gesture take priority.
final class ScrollableSegmentedControl: UISegmentedControl {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
