#if canImport(UIKit)
    import UIKit

    // MARK: - PRMCameraFocusView

    /// A tap-to-focus indicator that animates at the tap point.
    ///
    /// Configurable border color, width, and size. Respects Reduce Motion.
    ///
    /// ```swift
    /// let focusView = PRMCameraFocusView()
    /// focusView.show(at: tapPoint, in: parentView)
    /// ```
    public final class PRMCameraFocusView: UIView {
        // MARK: - Configuration

        /// The border color of the focus indicator.
        public var borderColor: UIColor = .white {
            didSet { layer.borderColor = borderColor.cgColor }
        }

        /// The border width of the focus indicator.
        public var borderWidth: CGFloat = 1.5 {
            didSet { layer.borderWidth = borderWidth }
        }

        /// The size (width and height) of the focus indicator.
        public var indicatorSize: CGFloat = 80 {
            didSet { invalidateIntrinsicContentSize() }
        }

        /// How long the focus indicator stays visible before fading out.
        public var visibleDuration: TimeInterval = 2.0

        /// How long the fade-in animation takes.
        public var fadeInDuration: TimeInterval = 0.15

        /// How long the fade-out animation takes.
        public var fadeOutDuration: TimeInterval = 0.3

        // MARK: - Private

        private var fadeOutTask: Task<Void, Never>?

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
            layer.borderColor = borderColor.cgColor
            layer.borderWidth = borderWidth
            alpha = 0
            isUserInteractionEnabled = false
        }

        // MARK: - Intrinsic Size

        override public var intrinsicContentSize: CGSize {
            CGSize(width: indicatorSize, height: indicatorSize)
        }

        // MARK: - Show / Hide

        /// Shows the focus indicator at the given center point.
        ///
        /// - Parameters:
        ///   - center: The center point in the parent view's coordinate space.
        ///   - parentView: The view to add the indicator to.
        public func show(at center: CGPoint, in parentView: UIView) {
            fadeOutTask?.cancel()
            fadeOutTask = nil

            if superview !== parentView {
                removeFromSuperview()
                parentView.addSubview(self)
            }

            let size = indicatorSize
            frame = CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size,
            )

            if UIAccessibility.isReduceMotionEnabled {
                alpha = 1
                transform = .identity
                scheduleFadeOut()
            } else {
                transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
                alpha = 0

                UIView.animate(withDuration: fadeInDuration, delay: 0, options: .curveEaseOut) {
                    self.alpha = 1
                    self.transform = .identity
                } completion: { _ in
                    self.scheduleFadeOut()
                }
            }
        }

        /// Hides the focus indicator immediately.
        public func hide() {
            fadeOutTask?.cancel()
            fadeOutTask = nil
            alpha = 0
            removeFromSuperview()
        }

        // MARK: - Private

        private func scheduleFadeOut() {
            fadeOutTask?.cancel()
            fadeOutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.visibleDuration))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.fadeOut()
                }
            }
        }

        private func fadeOut() {
            if UIAccessibility.isReduceMotionEnabled {
                alpha = 0
                removeFromSuperview()
            } else {
                UIView.animate(withDuration: fadeOutDuration, delay: 0, options: .curveEaseIn) {
                    self.alpha = 0
                } completion: { _ in
                    self.removeFromSuperview()
                }
            }
        }
    }
#endif
