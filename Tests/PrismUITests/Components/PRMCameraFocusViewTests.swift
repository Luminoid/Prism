#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import PrismUI

    // MARK: - PRMCameraFocusViewTests

    @Suite("PRMCameraFocusView")
    @MainActor
    struct PRMCameraFocusViewTests {
        // MARK: - Initialization

        @Test("Starts with alpha 0")
        func startsHidden() {
            let view = PRMCameraFocusView()
            #expect(view.alpha == 0)
        }

        @Test("Background is clear")
        func clearBackground() {
            let view = PRMCameraFocusView()
            #expect(view.backgroundColor == .clear)
        }

        @Test("User interaction is disabled")
        func noUserInteraction() {
            let view = PRMCameraFocusView()
            #expect(!view.isUserInteractionEnabled)
        }

        // MARK: - Default Configuration

        @Test("Default border color is white")
        func defaultBorderColor() {
            let view = PRMCameraFocusView()
            #expect(view.borderColor == .white)
        }

        @Test("Default border width is 1.5")
        func defaultBorderWidth() {
            let view = PRMCameraFocusView()
            #expect(view.borderWidth == 1.5)
        }

        @Test("Default indicator size is 80")
        func defaultSize() {
            let view = PRMCameraFocusView()
            #expect(view.indicatorSize == 80)
        }

        @Test("Default visible duration is 2 seconds")
        func defaultVisibleDuration() {
            let view = PRMCameraFocusView()
            #expect(view.visibleDuration == 2.0)
        }

        // MARK: - Intrinsic Size

        @Test("Intrinsic content size matches indicator size")
        func intrinsicSize() {
            let view = PRMCameraFocusView()
            #expect(view.intrinsicContentSize == CGSize(width: 80, height: 80))
        }

        @Test("Intrinsic content size updates when indicator size changes")
        func intrinsicSizeUpdates() {
            let view = PRMCameraFocusView()
            view.indicatorSize = 60
            #expect(view.intrinsicContentSize == CGSize(width: 60, height: 60))
        }

        // MARK: - Configuration Changes

        @Test("Border color updates layer")
        func borderColorUpdatesLayer() {
            let view = PRMCameraFocusView()
            view.borderColor = .red
            #expect(view.layer.borderColor == UIColor.red.cgColor)
        }

        @Test("Border width updates layer")
        func borderWidthUpdatesLayer() {
            let view = PRMCameraFocusView()
            view.borderWidth = 3.0
            #expect(view.layer.borderWidth == 3.0)
        }

        // MARK: - Show / Hide

        @Test("Show adds view to parent")
        func showAddsToParent() {
            let focusView = PRMCameraFocusView()
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            focusView.show(at: CGPoint(x: 160, y: 240), in: parent)
            #expect(focusView.superview === parent)
        }

        @Test("Show sets alpha to 1")
        func showSetsAlpha() async throws {
            let focusView = PRMCameraFocusView()
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            focusView.show(at: CGPoint(x: 160, y: 240), in: parent)
            // Allow animation to complete
            try await Task.sleep(for: .milliseconds(300))
            #expect(focusView.alpha == 1)
        }

        @Test("Hide resets alpha to 0")
        func hideSetsAlpha() {
            let focusView = PRMCameraFocusView()
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            focusView.show(at: CGPoint(x: 160, y: 240), in: parent)
            focusView.hide()
            #expect(focusView.alpha == 0)
        }

        @Test("Hide removes from superview")
        func hideRemovesFromSuperview() {
            let focusView = PRMCameraFocusView()
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            focusView.show(at: CGPoint(x: 160, y: 240), in: parent)
            focusView.hide()
            #expect(focusView.superview == nil)
        }

        @Test("Show positions view at center point")
        func showPositionsCorrectly() {
            let focusView = PRMCameraFocusView()
            focusView.indicatorSize = 80
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            focusView.show(at: CGPoint(x: 160, y: 240), in: parent)
            #expect(focusView.frame.origin.x == 120) // 160 - 40
            #expect(focusView.frame.origin.y == 200) // 240 - 40
            #expect(focusView.frame.width == 80)
            #expect(focusView.frame.height == 80)
        }
    }
#endif
