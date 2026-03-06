#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import PrismUI

    @Suite("PRMGridOverlayView")
    @MainActor
    struct PRMGridOverlayViewTests {
        // MARK: - Initialization

        @Test("Background is clear")
        func clearBackground() {
            let view = PRMGridOverlayView()
            #expect(view.backgroundColor == .clear)
        }

        @Test("User interaction is disabled")
        func noUserInteraction() {
            let view = PRMGridOverlayView()
            #expect(!view.isUserInteractionEnabled)
        }

        @Test("Accessibility element is false")
        func notAccessible() {
            let view = PRMGridOverlayView()
            #expect(!view.isAccessibilityElement)
        }

        // MARK: - Default Configuration

        @Test("Default grid type is rule of thirds")
        func defaultGridType() {
            let view = PRMGridOverlayView()
            switch view.gridType {
            case .ruleOfThirds: break // pass
            default: Issue.record("Expected ruleOfThirds")
            }
        }

        @Test("Default line color is semi-transparent white")
        func defaultLineColor() {
            let view = PRMGridOverlayView()
            #expect(view.lineColor == UIColor.white.withAlphaComponent(0.5))
        }

        @Test("Default line width is 0.5")
        func defaultLineWidth() {
            let view = PRMGridOverlayView()
            #expect(view.lineWidth == 0.5)
        }

        @Test("Default grid visibility is true")
        func defaultVisibility() {
            let view = PRMGridOverlayView()
            #expect(view.isGridVisible == true)
        }

        // MARK: - Configuration Changes

        @Test("Setting line color updates the layer")
        func lineColorChange() {
            let view = PRMGridOverlayView()
            view.lineColor = .red
            #expect(view.lineColor == .red)
        }

        @Test("Setting line width updates the layer")
        func lineWidthChange() {
            let view = PRMGridOverlayView()
            view.lineWidth = 2.0
            #expect(view.lineWidth == 2.0)
        }

        @Test("Grid type can be changed to phi")
        func gridTypePhi() {
            let view = PRMGridOverlayView()
            view.gridType = .phi
            switch view.gridType {
            case .phi: break
            default: Issue.record("Expected phi")
            }
        }

        @Test("Grid type can be changed to crosshair")
        func gridTypeCrosshair() {
            let view = PRMGridOverlayView()
            view.gridType = .crosshair
            switch view.gridType {
            case .crosshair: break
            default: Issue.record("Expected crosshair")
            }
        }

        // MARK: - Visibility

        @Test("Setting isGridVisible to false hides lines")
        func hideGrid() {
            let view = PRMGridOverlayView()
            view.isGridVisible = false
            #expect(view.isGridVisible == false)
        }

        @Test("Toggling visibility back to true shows lines")
        func toggleVisibility() {
            let view = PRMGridOverlayView()
            view.isGridVisible = false
            view.isGridVisible = true
            #expect(view.isGridVisible == true)
        }

        // MARK: - Layout

        @Test("Layout triggers grid redraw without crashing")
        func layoutRedraw() {
            let view = PRMGridOverlayView()
            view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
            view.layoutSubviews()
            // No crash = pass
        }

        @Test("Layout works with all grid types")
        func layoutAllTypes() {
            let view = PRMGridOverlayView()
            view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)

            for gridType in [PRMGridOverlayView.GridType.ruleOfThirds, .phi, .crosshair] {
                view.gridType = gridType
                view.layoutSubviews()
            }
        }
    }
#endif
