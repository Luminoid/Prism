#if canImport(UIKit) && canImport(CoreMotion)
    import Testing
    import UIKit
    @testable import PrismUI

    @Suite("PRMLevelIndicatorView")
    @MainActor
    struct PRMLevelIndicatorViewTests {
        // MARK: - Initialization

        @Test("Background is clear")
        func clearBackground() {
            let view = PRMLevelIndicatorView()
            #expect(view.backgroundColor == .clear)
        }

        @Test("User interaction is disabled")
        func noUserInteraction() {
            let view = PRMLevelIndicatorView()
            #expect(!view.isUserInteractionEnabled)
        }

        @Test("Accessibility element is enabled")
        func accessibilityEnabled() {
            let view = PRMLevelIndicatorView()
            #expect(view.isAccessibilityElement)
        }

        @Test("Accessibility label is set")
        func accessibilityLabel() {
            let view = PRMLevelIndicatorView()
            #expect(view.accessibilityLabel == "Level indicator")
        }

        // MARK: - Default Configuration

        @Test("Default line color is white")
        func defaultLineColor() {
            let view = PRMLevelIndicatorView()
            #expect(view.lineColor == .white)
        }

        @Test("Default leveled color is system yellow")
        func defaultLeveledColor() {
            let view = PRMLevelIndicatorView()
            #expect(view.leveledColor == .systemYellow)
        }

        @Test("Default line width is 2.0")
        func defaultLineWidth() {
            let view = PRMLevelIndicatorView()
            #expect(view.lineWidth == 2.0)
        }

        @Test("Default line length ratio is 0.3")
        func defaultLineLengthRatio() {
            let view = PRMLevelIndicatorView()
            #expect(view.lineLengthRatio == 0.3)
        }

        @Test("Default level threshold is 1.0 degrees")
        func defaultThreshold() {
            let view = PRMLevelIndicatorView()
            #expect(view.levelThreshold == 1.0)
        }

        @Test("Starts inactive")
        func startsInactive() {
            let view = PRMLevelIndicatorView()
            #expect(!view.isActive)
        }

        @Test("Starts with zero roll degrees")
        func startsAtZero() {
            let view = PRMLevelIndicatorView()
            #expect(view.currentRollDegrees == 0)
        }

        @Test("Starts not level")
        func startsNotLevel() {
            let view = PRMLevelIndicatorView()
            #expect(!view.isLevel)
        }

        // MARK: - Configuration Changes

        @Test("Line color can be changed")
        func lineColorChange() {
            let view = PRMLevelIndicatorView()
            view.lineColor = .red
            #expect(view.lineColor == .red)
        }

        @Test("Leveled color can be changed")
        func leveledColorChange() {
            let view = PRMLevelIndicatorView()
            view.leveledColor = .green
            #expect(view.leveledColor == .green)
        }

        @Test("Line width can be changed")
        func lineWidthChange() {
            let view = PRMLevelIndicatorView()
            view.lineWidth = 4.0
            #expect(view.lineWidth == 4.0)
        }

        @Test("Level threshold can be changed")
        func thresholdChange() {
            let view = PRMLevelIndicatorView()
            view.levelThreshold = 2.5
            #expect(view.levelThreshold == 2.5)
        }

        // MARK: - Active Toggle

        @Test("Setting active to true does not crash in simulator")
        func activateInSimulator() {
            let view = PRMLevelIndicatorView()
            view.isActive = true
            #expect(view.isActive)
            view.isActive = false
            #expect(!view.isActive)
        }

        @Test("Deactivating resets roll degrees")
        func deactivateResetsRoll() {
            let view = PRMLevelIndicatorView()
            view.isActive = true
            view.isActive = false
            #expect(view.currentRollDegrees == 0)
        }

        @Test("Deactivating resets isLevel")
        func deactivateResetsLevel() {
            let view = PRMLevelIndicatorView()
            view.isActive = true
            view.isActive = false
            #expect(!view.isLevel)
        }

        // MARK: - Layout

        @Test("Layout works without crashing")
        func layout() {
            let view = PRMLevelIndicatorView()
            view.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
            view.layoutSubviews()
        }
    }
#endif
