#if canImport(UIKit)
    import UIKit

    // MARK: - PRMAspectRatioMaskView

    /// Draws a dark mask outside the active crop area for a given aspect ratio.
    ///
    /// Use ``cropRect(in:)`` to get the unmasked rect for cropping captured photos.
    public final class PRMAspectRatioMaskView: UIView {
        // MARK: - Aspect ratio

        public enum AspectRatio: Sendable, Equatable {
            case ratio4x3
            case ratio16x9
            case ratio1x1
            /// No aspect-ratio constraint — the mask is hidden, the captured frame uses
            /// its full sensor extent. ``value`` is `nil` (there is no meaningful ratio
            /// to compute against) so any layout/crop math must gate on this case before
            /// reading the value.
            case unconstrained

            /// Width:height ratio, or `nil` for ``unconstrained``. Callers that compute
            /// crop rects must guard on the nil case rather than substituting a default,
            /// otherwise an "unconstrained" pass becomes an unintended 1:1 crop.
            public var value: CGFloat? {
                switch self {
                case .ratio4x3: 4.0 / 3.0
                case .ratio16x9: 16.0 / 9.0
                case .ratio1x1: 1.0
                case .unconstrained: nil
                }
            }
        }

        // MARK: - Configuration

        public var aspectRatio: AspectRatio = .unconstrained {
            didSet { setNeedsLayout() }
        }

        public var maskColor: UIColor = .black.withAlphaComponent(0.55) {
            didSet {
                [topMask, bottomMask, leftMask, rightMask].forEach { $0.backgroundColor = maskColor }
            }
        }

        public var borderColor: UIColor = .white {
            didSet { borderLayer.strokeColor = borderColor.cgColor }
        }

        public var borderWidth: CGFloat = 1.0 {
            didSet { borderLayer.lineWidth = borderWidth }
        }

        // MARK: - Private

        private let topMask = UIView()
        private let bottomMask = UIView()
        private let leftMask = UIView()
        private let rightMask = UIView()
        private let borderLayer = CAShapeLayer()

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
            for mask in [topMask, bottomMask, leftMask, rightMask] {
                mask.backgroundColor = maskColor
                addSubview(mask)
            }
            borderLayer.fillColor = nil
            borderLayer.strokeColor = borderColor.cgColor
            borderLayer.lineWidth = borderWidth
            layer.addSublayer(borderLayer)
        }

        // MARK: - Layout

        override public func layoutSubviews() {
            super.layoutSubviews()
            let crop = cropRect(in: bounds)
            topMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: crop.minY)
            bottomMask.frame = CGRect(x: 0, y: crop.maxY, width: bounds.width, height: bounds.height - crop.maxY)
            leftMask.frame = CGRect(x: 0, y: crop.minY, width: crop.minX, height: crop.height)
            rightMask.frame = CGRect(x: crop.maxX, y: crop.minY, width: bounds.width - crop.maxX, height: crop.height)
            borderLayer.path = UIBezierPath(rect: crop).cgPath

            let showMask = aspectRatio != .unconstrained
            [topMask, bottomMask, leftMask, rightMask].forEach { $0.isHidden = !showMask }
            borderLayer.isHidden = !showMask
        }

        // MARK: - Public

        /// Returns the crop rectangle for the current aspect ratio within `bounds`.
        /// Returns `bounds` unchanged when the active ratio is ``AspectRatio/unconstrained``.
        public func cropRect(in bounds: CGRect) -> CGRect {
            guard let target = aspectRatio.value else { return bounds }
            let boundsRatio = bounds.width / bounds.height
            let cropWidth: CGFloat
            let cropHeight: CGFloat
            if boundsRatio > target {
                cropHeight = bounds.height
                cropWidth = bounds.height * target
            } else {
                cropWidth = bounds.width
                cropHeight = bounds.width / target
            }
            let x = bounds.origin.x + (bounds.width - cropWidth) / 2
            let y = bounds.origin.y + (bounds.height - cropHeight) / 2
            return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
        }
    }
#endif
