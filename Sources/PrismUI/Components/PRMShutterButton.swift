#if canImport(UIKit)
    import UIKit

    // MARK: - PRMShutterButton

    /// A camera-app-style shutter button.
    ///
    /// Two interaction modes are supported and can be active simultaneously:
    /// - Tap: fires ``onTap`` (still photo).
    /// - Press-and-hold: fires ``onLongPressBegan`` / ``onLongPressEnded`` (video toggle).
    ///
    /// Visually it can morph between a *photo* state (white-filled circle) and a *recording*
    /// state (red rounded square inside a red ring) via ``setMode(_:animated:)``.
    public final class PRMShutterButton: UIView {
        // MARK: - Mode

        public enum Mode: Sendable, Equatable {
            /// White-filled circle.
            case photo
            /// Red ring + smaller filled red rounded square.
            case recording
            /// Pulsing red — used while actively recording.
            case recordingActive
        }

        // MARK: - Configuration

        public var ringColor: UIColor = .white { didSet { setNeedsLayout() } }
        public var ringWidth: CGFloat = 4 { didSet { setNeedsLayout() } }
        public var gapWidth: CGFloat = 4 { didSet { setNeedsLayout() } }
        public var photoFillColor: UIColor = .white { didSet { applyMode(animated: false) } }
        public var recordingFillColor: UIColor = .systemRed { didSet { applyMode(animated: false) } }
        public var buttonSize: CGFloat = 76 {
            didSet {
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        public var onTap: (() -> Void)?
        public var onLongPressBegan: (() -> Void)?
        public var onLongPressEnded: (() -> Void)?

        public private(set) var mode: Mode = .photo

        // MARK: - Private

        private let ringView = UIView()
        private let innerView = UIView()
        private var pulseAnimating = false

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
            isAccessibilityElement = true
            accessibilityLabel = String(localized: "Capture", bundle: .module)
            accessibilityTraits = .button

            addSubview(ringView)
            ringView.addSubview(innerView)
            ringView.isUserInteractionEnabled = false
            innerView.isUserInteractionEnabled = false

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.4
            addGestureRecognizer(longPress)
        }

        // MARK: - Sizing

        override public var intrinsicContentSize: CGSize {
            CGSize(width: buttonSize, height: buttonSize)
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            let size = min(bounds.width, bounds.height)
            guard size > 0 else { return }

            ringView.frame = CGRect(x: 0, y: 0, width: size, height: size)
            ringView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            ringView.layer.cornerRadius = size / 2
            ringView.layer.borderWidth = ringWidth
            ringView.layer.borderColor = ringColor.cgColor
            ringView.backgroundColor = .clear

            let inset = ringWidth + gapWidth
            let innerSize = size - inset * 2
            innerView.frame = CGRect(x: inset, y: inset, width: innerSize, height: innerSize)
            applyMode(animated: false)
        }

        // MARK: - Mode

        public func setMode(_ mode: Mode, animated: Bool = true) {
            guard mode != self.mode else { return }
            self.mode = mode
            applyMode(animated: animated)
        }

        private func applyMode(animated: Bool) {
            stopPulse()
            let innerSize = innerView.bounds.size
            let block: () -> Void = { [self] in
                switch mode {
                case .photo:
                    innerView.backgroundColor = photoFillColor
                    innerView.layer.cornerRadius = innerSize.width / 2
                    ringView.layer.borderColor = ringColor.cgColor
                case .recording, .recordingActive:
                    innerView.backgroundColor = recordingFillColor
                    innerView.layer.cornerRadius = innerSize.width * 0.2
                    ringView.layer.borderColor = recordingFillColor.cgColor
                }
            }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut, animations: block)
            } else {
                block()
            }
            if case .recordingActive = mode { startPulse() }
        }

        private func startPulse() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            pulseAnimating = true
            UIView.animate(
                withDuration: 0.7,
                delay: 0,
                options: [.autoreverse, .repeat, .curveEaseInOut],
                animations: { [self] in innerView.alpha = 0.55 }
            )
        }

        private func stopPulse() {
            pulseAnimating = false
            innerView.layer.removeAllAnimations()
            innerView.alpha = 1.0
        }

        // MARK: - Gestures

        @objc private func handleTap() {
            onTap?()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                onLongPressBegan?()
            case .ended, .cancelled:
                onLongPressEnded?()
            default: break
            }
        }

        // MARK: - Press feedback

        override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            animatePress(true)
        }

        override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            animatePress(false)
        }

        override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            animatePress(false)
        }

        private func animatePress(_ pressed: Bool) {
            let scale: CGFloat = pressed ? 0.9 : 1.0
            if UIAccessibility.isReduceMotionEnabled {
                innerView.transform = CGAffineTransform(scaleX: scale, y: scale)
            } else {
                UIView.animate(withDuration: 0.1) { [self] in
                    innerView.transform = CGAffineTransform(scaleX: scale, y: scale)
                }
            }
        }
    }
#endif
