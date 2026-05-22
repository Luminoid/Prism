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
            /// White ring + white-filled circle. Photo / Live / Portrait / Night / Pano.
            case photo
            /// White ring + smaller red filled circle. Video / Slo-Mo, idle (ready to record).
            case recording
            /// White ring + smaller red rounded square, pulsing. Actively recording.
            case recordingActive
        }

        // MARK: - Configuration

        public var ringColor: UIColor = .white { didSet { setNeedsLayout() } }
        public var ringWidth: CGFloat = 4 { didSet { setNeedsLayout() } }
        public var gapWidth: CGFloat = 4 { didSet { setNeedsLayout() } }
        public var photoFillColor: UIColor = .white { didSet { applyMode(animated: false) } }
        public var recordingFillColor: UIColor = .systemRed { didSet { applyMode(animated: false) } }

        /// Intrinsic width + height of the shutter button. Default `76` matches the
        /// iOS Camera app shutter. **Must stay ≥ 44pt** per Apple HIG hit-target rules:
        /// VoiceOver users and any user with motor accessibility needs the full 44pt
        /// touch target to reliably activate the control. Sizes smaller than 44pt are
        /// rejected at runtime (debug-only assertion); host apps that want a visually
        /// smaller button should keep `buttonSize` at 44+ and shrink only the inner
        /// circle/ring via the color/width knobs above.
        public var buttonSize: CGFloat = 76 {
            didSet {
                assert(buttonSize >= 44, "PRMShutterButton.buttonSize (\(buttonSize)) is below the 44pt HIG hit-target minimum.")
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

            // `innerView` is always centered within the ring at the *photo* size; the
            // `recording*` modes apply a `transform` to shrink it to ~46% of the inner
            // box (Apple Camera's red dot/square sits well inside the ring).
            let inset = ringWidth + gapWidth
            let innerSize = size - inset * 2
            innerView.bounds = CGRect(x: 0, y: 0, width: innerSize, height: innerSize)
            innerView.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
            // Apple-Camera proportions: inner dot/square is ~46% of the full inner box
            // when in either recording state. Photo state fills the inner box.
            let recordingScale: CGFloat = 0.46
            let block: () -> Void = { [self] in
                switch mode {
                case .photo:
                    innerView.backgroundColor = photoFillColor
                    innerView.layer.cornerRadius = innerSize.width / 2
                    innerView.transform = .identity
                    ringView.layer.borderColor = ringColor.cgColor
                case .recording:
                    innerView.backgroundColor = recordingFillColor
                    // Round circle when idle — "ready to record" affordance.
                    innerView.layer.cornerRadius = innerSize.width / 2
                    innerView.transform = CGAffineTransform(scaleX: recordingScale, y: recordingScale)
                    ringView.layer.borderColor = ringColor.cgColor
                case .recordingActive:
                    innerView.backgroundColor = recordingFillColor
                    // Rounded square while actively recording — "tap to stop" affordance.
                    innerView.layer.cornerRadius = innerSize.width * 0.12
                    innerView.transform = CGAffineTransform(scaleX: recordingScale, y: recordingScale)
                    ringView.layer.borderColor = ringColor.cgColor
                }
            }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.75,
                    initialSpringVelocity: 0.4,
                    options: .curveEaseOut,
                    animations: block
                )
            } else {
                block()
            }
            if case .recordingActive = mode { startPulse() }
        }

        private func startPulse() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(
                withDuration: 0.7,
                delay: 0,
                options: [.autoreverse, .repeat, .curveEaseInOut],
                animations: { [self] in innerView.alpha = 0.55 }
            )
        }

        private func stopPulse() {
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
            // Press feedback composes with the mode scale (1.0 for photo, 0.46 for
            // recording states) so the recording dot doesn't briefly jump to full size
            // while the user is pressing the button.
            let baseScale: CGFloat = (mode == .photo) ? 1.0 : 0.46
            let pressScale: CGFloat = pressed ? 0.9 : 1.0
            let composed = baseScale * pressScale
            let block = { [self] in
                innerView.transform = CGAffineTransform(scaleX: composed, y: composed)
            }
            if UIAccessibility.isReduceMotionEnabled {
                block()
            } else {
                UIView.animate(withDuration: 0.1, animations: block)
            }
        }
    }
#endif
