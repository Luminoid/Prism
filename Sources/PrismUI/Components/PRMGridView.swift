#if canImport(UIKit)
    import UIKit

    // MARK: - PRMGridView

    /// Camera composition grid overlay.
    ///
    /// Supports rule-of-thirds, phi/golden ratio, crosshair, and Fibonacci spiral.
    public final class PRMGridView: UIView {
        // MARK: - Grid type

        public enum GridType: Sendable {
            case ruleOfThirds
            case phi
            case crosshair
            case fibonacci
        }

        // MARK: - Configuration

        public var gridType: GridType = .ruleOfThirds {
            didSet { updateGrid() }
        }

        public var lineColor: UIColor = .white.withAlphaComponent(0.5) {
            didSet { shapeLayer.strokeColor = lineColor.cgColor }
        }

        public var lineWidth: CGFloat = 0.5 {
            didSet { shapeLayer.lineWidth = lineWidth }
        }

        public var isGridVisible: Bool = true {
            didSet { shapeLayer.isHidden = !isGridVisible }
        }

        // MARK: - Private

        private let shapeLayer = CAShapeLayer()

        // MARK: - Init

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

        // MARK: - Drawing

        private func updateGrid() {
            let phi: CGFloat = 1.0 / 1.618_033_988_749_895
            let path: UIBezierPath = switch gridType {
            case .ruleOfThirds: makeLinesPath(ratios: [1.0 / 3.0, 2.0 / 3.0])
            case .phi: makeLinesPath(ratios: [1.0 - phi, phi])
            case .crosshair: makeLinesPath(ratios: [0.5])
            case .fibonacci: makeFibonacciPath()
            }
            shapeLayer.path = path.cgPath
        }

        private func makeLinesPath(ratios: [CGFloat]) -> UIBezierPath {
            let path = UIBezierPath()
            let w = bounds.width
            let h = bounds.height
            for ratio in ratios {
                path.move(to: CGPoint(x: 0, y: h * ratio))
                path.addLine(to: CGPoint(x: w, y: h * ratio))
                path.move(to: CGPoint(x: w * ratio, y: 0))
                path.addLine(to: CGPoint(x: w * ratio, y: h))
            }
            return path
        }

        private func makeFibonacciPath() -> UIBezierPath {
            // Approximate a golden-ratio spiral using quarter arcs in subdivided squares.
            let path = UIBezierPath()
            let phi: CGFloat = 1.618_033_988_749_895
            var rect = bounds
            var clockwise = true
            for _ in 0 ..< 6 {
                let shortSide = min(rect.width, rect.height)
                let square = if rect.width >= rect.height {
                    CGRect(x: clockwise ? rect.minX : rect.maxX - shortSide, y: rect.minY, width: shortSide, height: shortSide)
                } else {
                    CGRect(x: rect.minX, y: clockwise ? rect.minY : rect.maxY - shortSide, width: shortSide, height: shortSide)
                }
                let center = CGPoint(x: clockwise ? square.maxX : square.minX, y: clockwise ? square.maxY : square.minY)
                let radius = shortSide
                let start: CGFloat = clockwise ? .pi : 0
                let end: CGFloat = clockwise ? .pi * 1.5 : -.pi / 2
                path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: !clockwise)

                if rect.width >= rect.height {
                    let remaining = rect.width - shortSide
                    rect = CGRect(
                        x: clockwise ? rect.minX + shortSide : rect.minX,
                        y: rect.minY, width: remaining, height: rect.height
                    )
                } else {
                    let remaining = rect.height - shortSide
                    rect = CGRect(
                        x: rect.minX,
                        y: clockwise ? rect.minY + shortSide : rect.minY,
                        width: rect.width, height: remaining
                    )
                }
                clockwise.toggle()
                if min(rect.width, rect.height) < shortSide / phi { break }
            }
            return path
        }
    }
#endif
