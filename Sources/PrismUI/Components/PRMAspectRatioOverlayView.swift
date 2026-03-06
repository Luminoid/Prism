#if canImport(UIKit)
    import UIKit

    // MARK: - PRMAspectRatioOverlayView

    /// Draws a dark overlay outside the active crop area for a given aspect ratio.
    ///
    /// Use `cropRect(in:)` to get the unmasked area for cropping captured photos.
    /// ```swift
    /// let overlay = PRMAspectRatioOverlayView()
    /// overlay.aspectRatio = .ratio16x9
    /// previewView.addSubview(overlay)
    ///
    /// let cropArea = overlay.cropRect(in: overlay.bounds)
    /// ```
    public final class PRMAspectRatioOverlayView: UIView {
        // MARK: - Aspect Ratio

        /// The available aspect ratio presets.
        public enum AspectRatio: Sendable {
            /// 4:3 — standard photo.
            case ratio4x3
            /// 16:9 — widescreen.
            case ratio16x9
            /// 1:1 — square.
            case ratio1x1
            /// Full frame — no crop overlay.
            case full
        }

        // MARK: - Configuration

        /// The aspect ratio to display. Redraws on change.
        public var aspectRatio: AspectRatio = .full {
            didSet { setNeedsLayout() }
        }

        /// The color of the masked (non-crop) area.
        public var maskColor: UIColor = .black.withAlphaComponent(0.5) {
            didSet {
                topMask.backgroundColor = maskColor
                bottomMask.backgroundColor = maskColor
                leftMask.backgroundColor = maskColor
                rightMask.backgroundColor = maskColor
            }
        }

        /// The border color of the crop area.
        public var borderColor: UIColor = .white {
            didSet { borderLayer.strokeColor = borderColor.cgColor }
        }

        /// The border width of the crop area.
        public var borderWidth: CGFloat = 1.0 {
            didSet { borderLayer.lineWidth = borderWidth }
        }

        // MARK: - Private

        private let topMask = UIView()
        private let bottomMask = UIView()
        private let leftMask = UIView()
        private let rightMask = UIView()
        private let borderLayer = CAShapeLayer()

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

            // Hide masks and border when full frame
            let showMask = aspectRatio != .full
            topMask.isHidden = !showMask
            bottomMask.isHidden = !showMask
            leftMask.isHidden = !showMask
            rightMask.isHidden = !showMask
            borderLayer.isHidden = !showMask
        }

        // MARK: - Public API

        /// Returns the crop rectangle for the current aspect ratio within the given bounds.
        ///
        /// For `.full`, returns the entire bounds.
        public func cropRect(in bounds: CGRect) -> CGRect {
            guard aspectRatio != .full else { return bounds }

            let targetRatio = aspectRatioValue
            let boundsRatio = bounds.width / bounds.height

            let cropWidth: CGFloat
            let cropHeight: CGFloat

            if boundsRatio > targetRatio {
                // Bounds are wider — fit height, crop width
                cropHeight = bounds.height
                cropWidth = bounds.height * targetRatio
            } else {
                // Bounds are taller — fit width, crop height
                cropWidth = bounds.width
                cropHeight = bounds.width / targetRatio
            }

            let x = bounds.origin.x + (bounds.width - cropWidth) / 2
            let y = bounds.origin.y + (bounds.height - cropHeight) / 2

            return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
        }

        // MARK: - Private

        private var aspectRatioValue: CGFloat {
            switch aspectRatio {
            case .ratio4x3: 4.0 / 3.0
            case .ratio16x9: 16.0 / 9.0
            case .ratio1x1: 1.0
            case .full: 1.0
            }
        }
    }
#endif
