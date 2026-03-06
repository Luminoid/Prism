#if canImport(UIKit)
    import UIKit

    // MARK: - PRMCameraButton

    /// A minimal circular shutter button for camera capture.
    ///
    /// Configurable colors and sizes. Shows a press state animation.
    ///
    /// ```swift
    /// let button = PRMCameraButton()
    /// button.onTap = { print("Capture!") }
    /// ```
    public final class PRMCameraButton: UIView {
        // MARK: - Configuration

        /// The outer ring color.
        public var ringColor: UIColor = .white {
            didSet { setNeedsLayout() }
        }

        /// The inner circle color.
        public var fillColor: UIColor = .white {
            didSet { innerCircle.backgroundColor = fillColor }
        }

        /// The overall button size (outer diameter).
        public var buttonSize: CGFloat = 72 {
            didSet {
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        /// The width of the outer ring.
        public var ringWidth: CGFloat = 4 {
            didSet { setNeedsLayout() }
        }

        /// The gap between the outer ring and inner circle.
        public var gapWidth: CGFloat = 4 {
            didSet { setNeedsLayout() }
        }

        /// Called when the button is tapped.
        public var onTap: (() -> Void)?

        // MARK: - Private

        private let outerRing = UIView()
        private let innerCircle = UIView()

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
            isAccessibilityElement = true
            accessibilityLabel = String(localized: "Capture", bundle: .module)
            accessibilityTraits = .button

            addSubview(outerRing)
            outerRing.addSubview(innerCircle)

            outerRing.isUserInteractionEnabled = false
            innerCircle.isUserInteractionEnabled = false

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)
        }

        // MARK: - Intrinsic Size

        override public var intrinsicContentSize: CGSize {
            CGSize(width: buttonSize, height: buttonSize)
        }

        // MARK: - Layout

        override public func layoutSubviews() {
            super.layoutSubviews()

            let size = min(bounds.width, bounds.height)
            guard size > 0 else { return }

            outerRing.frame = CGRect(x: 0, y: 0, width: size, height: size)
            outerRing.center = CGPoint(x: bounds.midX, y: bounds.midY)
            outerRing.layer.cornerRadius = size / 2
            outerRing.layer.borderWidth = ringWidth
            outerRing.layer.borderColor = ringColor.cgColor
            outerRing.backgroundColor = .clear

            let inset = ringWidth + gapWidth
            let innerSize = size - inset * 2
            innerCircle.frame = CGRect(x: inset, y: inset, width: innerSize, height: innerSize)
            innerCircle.layer.cornerRadius = innerSize / 2
            innerCircle.backgroundColor = fillColor
        }

        // MARK: - Touch Feedback

        override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            animatePress(pressed: true)
        }

        override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            animatePress(pressed: false)
        }

        override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            animatePress(pressed: false)
        }

        private func animatePress(pressed: Bool) {
            let scale: CGFloat = pressed ? 0.9 : 1.0
            if UIAccessibility.isReduceMotionEnabled {
                innerCircle.transform = CGAffineTransform(scaleX: scale, y: scale)
            } else {
                UIView.animate(withDuration: 0.1) {
                    self.innerCircle.transform = CGAffineTransform(scaleX: scale, y: scale)
                }
            }
        }

        // MARK: - Actions

        @objc
        private func handleTap() {
            onTap?()
        }
    }
#endif
