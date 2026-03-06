#if canImport(UIKit)
    import UIKit

    // MARK: - PRMGridOverlayView

    /// Draws a composition grid overlay for camera viewfinders.
    ///
    /// Supports rule of thirds, golden ratio (phi), and crosshair grid types.
    /// ```swift
    /// let grid = PRMGridOverlayView()
    /// grid.gridType = .ruleOfThirds
    /// previewView.addSubview(grid)
    /// ```
    public final class PRMGridOverlayView: UIView {
        // MARK: - Grid Type

        /// The type of composition grid to display.
        public enum GridType: Sendable {
            /// Two horizontal + two vertical lines at 1/3 and 2/3 positions.
            case ruleOfThirds
            /// Two horizontal + two vertical lines at golden ratio (~0.382 and ~0.618) positions.
            case phi
            /// A center crosshair.
            case crosshair
        }

        // MARK: - Configuration

        /// The grid pattern to display. Redraws on change.
        public var gridType: GridType = .ruleOfThirds {
            didSet { updateGrid() }
        }

        /// The color of the grid lines.
        public var lineColor: UIColor = .white.withAlphaComponent(0.5) {
            didSet { shapeLayer.strokeColor = lineColor.cgColor }
        }

        /// The width of the grid lines.
        public var lineWidth: CGFloat = 0.5 {
            didSet { shapeLayer.lineWidth = lineWidth }
        }

        /// Whether the grid is visible.
        public var isGridVisible: Bool = true {
            didSet { shapeLayer.isHidden = !isGridVisible }
        }

        // MARK: - Private

        private let shapeLayer = CAShapeLayer()

        // MARK: - Initialization

        public init() {
            super.init(frame: .zero)
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Use init() instead")
        }

        private func setup() {
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false

            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = lineColor.cgColor
            shapeLayer.lineWidth = lineWidth
            layer.addSublayer(shapeLayer)
        }

        // MARK: - Layout

        override public func layoutSubviews() {
            super.layoutSubviews()
            shapeLayer.frame = bounds
            updateGrid()
        }

        // MARK: - Grid Drawing

        private func updateGrid() {
            let path: UIBezierPath = switch gridType {
            case .ruleOfThirds:
                makeThirdsPath()
            case .phi:
                makePhiPath()
            case .crosshair:
                makeCrosshairPath()
            }
            shapeLayer.path = path.cgPath
        }

        private func makeThirdsPath() -> UIBezierPath {
            makeLinesPath(ratios: [1.0 / 3.0, 2.0 / 3.0])
        }

        private func makePhiPath() -> UIBezierPath {
            let phi: CGFloat = 1.0 / 1.618033988749895
            return makeLinesPath(ratios: [1.0 - phi, phi])
        }

        private func makeLinesPath(ratios: [CGFloat]) -> UIBezierPath {
            let path = UIBezierPath()
            let width = bounds.width
            let height = bounds.height

            for ratio in ratios {
                // Horizontal line
                path.move(to: CGPoint(x: 0, y: height * ratio))
                path.addLine(to: CGPoint(x: width, y: height * ratio))
                // Vertical line
                path.move(to: CGPoint(x: width * ratio, y: 0))
                path.addLine(to: CGPoint(x: width * ratio, y: height))
            }

            return path
        }

        private func makeCrosshairPath() -> UIBezierPath {
            let path = UIBezierPath()
            let midX = bounds.midX
            let midY = bounds.midY

            // Horizontal center line
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: bounds.width, y: midY))
            // Vertical center line
            path.move(to: CGPoint(x: midX, y: 0))
            path.addLine(to: CGPoint(x: midX, y: bounds.height))

            return path
        }
    }
#endif
