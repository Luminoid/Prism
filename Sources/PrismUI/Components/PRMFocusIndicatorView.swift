#if canImport(UIKit)
    import UIKit

    // MARK: - PRMFocusIndicatorView

    /// A tap-to-focus indicator that animates at the tap point.
    public final class PRMFocusIndicatorView: UIView {
        // MARK: - Configuration

        public var borderColor: UIColor = .systemYellow {
            didSet { layer.borderColor = borderColor.cgColor }
        }

        public var borderWidth: CGFloat = 1.0 {
            didSet { layer.borderWidth = borderWidth }
        }

        public var indicatorSize: CGFloat = 80 {
            didSet { invalidateIntrinsicContentSize() }
        }

        public var visibleDuration: TimeInterval = 1.5
        public var fadeInDuration: TimeInterval = 0.15
        public var fadeOutDuration: TimeInterval = 0.3

        // MARK: - Private

        private var fadeOutTask: Task<Void, Never>?

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
            layer.borderColor = borderColor.cgColor
            layer.borderWidth = borderWidth
            alpha = 0
            isUserInteractionEnabled = false
        }

        override public var intrinsicContentSize: CGSize {
            CGSize(width: indicatorSize, height: indicatorSize)
        }

        // MARK: - Show / Hide

        /// Shows the indicator centered at `center` in `parent`'s coordinate space.
        public func show(at center: CGPoint, in parent: UIView) {
            fadeOutTask?.cancel()
            fadeOutTask = nil

            if superview !== parent {
                removeFromSuperview()
                parent.addSubview(self)
            }
            let size = indicatorSize
            let half = size / 2
            let clampedX = min(max(center.x, half), parent.bounds.width - half)
            let clampedY = min(max(center.y, half), parent.bounds.height - half)
            frame = CGRect(x: clampedX - half, y: clampedY - half, width: size, height: size)

            if UIAccessibility.isReduceMotionEnabled {
                alpha = 1
                transform = .identity
                scheduleFadeOut()
            } else {
                transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
                alpha = 0
                UIView.animate(withDuration: fadeInDuration, delay: 0, options: .curveEaseOut) {
                    self.alpha = 1
                    self.transform = .identity
                } completion: { _ in
                    self.scheduleFadeOut()
                }
            }
        }

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
                await MainActor.run { self.fadeOut() }
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
