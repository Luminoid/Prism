#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import PrismUI

    // MARK: - PRMCameraButtonTests

    @Suite("PRMCameraButton")
    @MainActor
    struct PRMCameraButtonTests {
        // MARK: - Initialization

        @Test("Default button size is 72")
        func defaultSize() {
            let button = PRMCameraButton()
            #expect(button.buttonSize == 72)
        }

        @Test("Default ring color is white")
        func defaultRingColor() {
            let button = PRMCameraButton()
            #expect(button.ringColor == .white)
        }

        @Test("Default fill color is white")
        func defaultFillColor() {
            let button = PRMCameraButton()
            #expect(button.fillColor == .white)
        }

        @Test("Default ring width is 4")
        func defaultRingWidth() {
            let button = PRMCameraButton()
            #expect(button.ringWidth == 4)
        }

        @Test("Default gap width is 4")
        func defaultGapWidth() {
            let button = PRMCameraButton()
            #expect(button.gapWidth == 4)
        }

        @Test("Background is clear")
        func clearBackground() {
            let button = PRMCameraButton()
            #expect(button.backgroundColor == .clear)
        }

        // MARK: - Accessibility

        @Test("Is accessibility element")
        func isAccessibilityElement() {
            let button = PRMCameraButton()
            #expect(button.isAccessibilityElement)
        }

        @Test("Accessibility traits include button")
        func accessibilityTraits() {
            let button = PRMCameraButton()
            #expect(button.accessibilityTraits.contains(.button))
        }

        @Test("Has accessibility label")
        func accessibilityLabel() {
            let button = PRMCameraButton()
            #expect(button.accessibilityLabel != nil)
            #expect(button.accessibilityLabel?.isEmpty == false)
        }

        // MARK: - Intrinsic Size

        @Test("Intrinsic content size matches button size")
        func intrinsicSize() {
            let button = PRMCameraButton()
            #expect(button.intrinsicContentSize == CGSize(width: 72, height: 72))
        }

        @Test("Intrinsic size updates when button size changes")
        func intrinsicSizeUpdates() {
            let button = PRMCameraButton()
            button.buttonSize = 60
            #expect(button.intrinsicContentSize == CGSize(width: 60, height: 60))
        }

        // MARK: - Configuration Changes

        @Test("Ring color can be changed")
        func changeRingColor() {
            let button = PRMCameraButton()
            button.ringColor = .red
            #expect(button.ringColor == .red)
        }

        @Test("Fill color can be changed")
        func changeFillColor() {
            let button = PRMCameraButton()
            button.fillColor = .blue
            #expect(button.fillColor == .blue)
        }

        // MARK: - Tap

        @Test("onTap closure is called")
        func onTapCalled() {
            let button = PRMCameraButton()
            var called = false
            button.onTap = { called = true }
            button.onTap?()
            #expect(called)
        }

        // MARK: - Layout

        @Test("Layout creates circular outer ring")
        func circularRing() {
            let button = PRMCameraButton()
            button.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
            button.layoutSubviews()
            // The outer ring should have cornerRadius = size/2
            let outerRing = button.subviews.first
            #expect(outerRing != nil)
            #expect(outerRing?.layer.cornerRadius == 36)
        }
    }
#endif
