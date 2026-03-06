#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import PrismUI

    @Suite("PRMAspectRatioOverlayView")
    @MainActor
    struct PRMAspectRatioOverlayViewTests {
        private let testBounds = CGRect(x: 0, y: 0, width: 300, height: 400)

        // MARK: - Initialization

        @Test("Background is clear")
        func clearBackground() {
            let view = PRMAspectRatioOverlayView()
            #expect(view.backgroundColor == .clear)
        }

        @Test("User interaction is disabled")
        func noUserInteraction() {
            let view = PRMAspectRatioOverlayView()
            #expect(!view.isUserInteractionEnabled)
        }

        @Test("Accessibility element is false")
        func notAccessible() {
            let view = PRMAspectRatioOverlayView()
            #expect(!view.isAccessibilityElement)
        }

        // MARK: - Default Configuration

        @Test("Default aspect ratio is full")
        func defaultFull() {
            let view = PRMAspectRatioOverlayView()
            switch view.aspectRatio {
            case .full: break
            default: Issue.record("Expected full")
            }
        }

        @Test("Default border color is white")
        func defaultBorderColor() {
            let view = PRMAspectRatioOverlayView()
            #expect(view.borderColor == .white)
        }

        @Test("Default border width is 1.0")
        func defaultBorderWidth() {
            let view = PRMAspectRatioOverlayView()
            #expect(view.borderWidth == 1.0)
        }

        // MARK: - Configuration Changes

        @Test("Mask color can be changed")
        func maskColorChange() {
            let view = PRMAspectRatioOverlayView()
            let color = UIColor.red.withAlphaComponent(0.3)
            view.maskColor = color
            #expect(view.maskColor == color)
        }

        @Test("Border color can be changed")
        func borderColorChange() {
            let view = PRMAspectRatioOverlayView()
            view.borderColor = .yellow
            #expect(view.borderColor == .yellow)
        }

        @Test("Border width can be changed")
        func borderWidthChange() {
            let view = PRMAspectRatioOverlayView()
            view.borderWidth = 3.0
            #expect(view.borderWidth == 3.0)
        }

        // MARK: - Crop Rect — Full

        @Test("Full ratio returns entire bounds")
        func fullCropRect() {
            let view = PRMAspectRatioOverlayView()
            view.aspectRatio = .full
            let crop = view.cropRect(in: testBounds)
            #expect(crop == testBounds)
        }

        // MARK: - Crop Rect — 1:1

        @Test("1:1 crop is centered square")
        func squareCropRect() {
            let view = PRMAspectRatioOverlayView()
            view.aspectRatio = .ratio1x1
            let crop = view.cropRect(in: testBounds)

            // In 300x400 bounds, square should be 300x300 centered
            #expect(crop.width == 300)
            #expect(crop.height == 300)
            #expect(crop.origin.x == 0)
            #expect(crop.origin.y == 50)
        }

        // MARK: - Crop Rect — 4:3

        @Test("4:3 crop is centered")
        func ratio4x3CropRect() {
            let view = PRMAspectRatioOverlayView()
            view.aspectRatio = .ratio4x3
            let crop = view.cropRect(in: testBounds)

            // 4:3 = 1.333..., in 300x400 bounds:
            // width fits: 300, height = 300 / (4/3) = 225
            #expect(crop.width == 300)
            #expect(crop.height == 225)
            #expect(crop.origin.x == 0)
            #expect(abs(crop.origin.y - 87.5) < 0.01)
        }

        // MARK: - Crop Rect — 16:9

        @Test("16:9 crop is centered")
        func ratio16x9CropRect() {
            let view = PRMAspectRatioOverlayView()
            view.aspectRatio = .ratio16x9
            let crop = view.cropRect(in: testBounds)

            // 16:9 = 1.778..., in 300x400 bounds:
            // width fits: 300, height = 300 / (16/9) = 168.75
            #expect(crop.width == 300)
            #expect(crop.height == 168.75)
            #expect(crop.origin.x == 0)
            #expect(abs(crop.origin.y - 115.625) < 0.01)
        }

        // MARK: - Crop Rect — Landscape Bounds

        @Test("Crop rect works in landscape bounds")
        func landscapeBounds() {
            let view = PRMAspectRatioOverlayView()
            view.aspectRatio = .ratio1x1
            let landscape = CGRect(x: 0, y: 0, width: 400, height: 300)
            let crop = view.cropRect(in: landscape)

            // In 400x300 landscape, square should be 300x300 centered
            #expect(crop.width == 300)
            #expect(crop.height == 300)
            #expect(crop.origin.x == 50)
            #expect(crop.origin.y == 0)
        }

        // MARK: - Layout

        @Test("Layout with each aspect ratio does not crash")
        func layoutAllRatios() {
            let view = PRMAspectRatioOverlayView()
            view.frame = testBounds

            for ratio in [
                PRMAspectRatioOverlayView.AspectRatio.full,
                .ratio4x3, .ratio16x9, .ratio1x1,
            ] {
                view.aspectRatio = ratio
                view.layoutSubviews()
            }
        }

        @Test("Aspect ratio change triggers layout")
        func ratioChangeLayout() {
            let view = PRMAspectRatioOverlayView()
            view.frame = testBounds
            view.aspectRatio = .ratio16x9
            view.layoutSubviews()
            // No crash = pass
        }
    }
#endif
