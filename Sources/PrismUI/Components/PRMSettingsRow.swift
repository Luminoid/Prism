#if canImport(UIKit)
    import SnapKit
    import UIKit

    /// A single row inside ``PRMSettingsDrawerView``. Configured with an SF Symbol, title,
    /// value label, and an arbitrary content view (slider, segmented control, chip strip, etc.).
    ///
    /// The row is collapsible: tapping the header toggles ``isExpanded`` and animates the
    /// content view in/out. The drawer owns layout — each row reports its own intrinsic size
    /// changes via `invalidateIntrinsicContentSize()`.
    public final class PRMSettingsRow: UIView {
        // MARK: - Configuration

        public var title: String {
            didSet { titleLabel.text = title }
        }

        public var valueText: String? {
            didSet { valueLabel.text = valueText }
        }

        public var symbolName: String {
            didSet { symbolView.image = UIImage(systemName: symbolName) }
        }

        public var isExpanded: Bool {
            didSet { applyExpansion(animated: true) }
        }

        /// Title font. Override to match the host app's type ramp.
        public var titleFont: UIFont = .systemFont(ofSize: 13, weight: .semibold) {
            didSet { titleLabel.font = titleFont }
        }

        /// Value-label font. Defaults to a monospaced digit font for tabular numerics.
        public var valueFont: UIFont = .monospacedSystemFont(ofSize: 11, weight: .medium) {
            didSet { valueLabel.font = valueFont }
        }

        public var onToggle: ((Bool) -> Void)?

        /// Tap handler for a disabled row. Fires when the content area is tapped while the
        /// row is disabled (see ``setDisabled(message:)``). The row stays collapsible — header
        /// taps still toggle expansion regardless.
        public var onDisabledTap: ((String) -> Void)?

        /// Whether the row's content is disabled. Header (expand/collapse) stays interactive.
        public private(set) var isContentDisabled: Bool = false
        /// Explanation surfaced when a disabled row's content area is tapped.
        public private(set) var disabledMessage: String?

        /// Disables the content area with an explanation. Pass `nil` to re-enable. The header
        /// row (icon, title, value, chevron) stays interactive so the user can still collapse
        /// the section.
        public func setDisabled(message: String?) {
            disabledMessage = message
            isContentDisabled = message != nil
            contentView.isUserInteractionEnabled = !isContentDisabled
            contentView.alpha = isContentDisabled ? 0.35 : 1.0
            disabledOverlay.isHidden = !isContentDisabled
        }

        // MARK: - Subviews

        private let headerButton = UIControl()
        private let symbolView = UIImageView()
        private let titleLabel = UILabel()
        private let valueLabel = UILabel()
        private let chevronView = UIImageView()
        private let contentContainer = UIView()
        private let contentView: UIView
        private let disabledOverlay = UIControl()

        // MARK: - Init

        public init(
            symbolName: String,
            title: String,
            valueText: String? = nil,
            isExpanded: Bool = true,
            content: UIView
        ) {
            self.symbolName = symbolName
            self.title = title
            self.valueText = valueText
            self.isExpanded = isExpanded
            contentView = content
            super.init(frame: .zero)
            setup()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Use init(symbolName:title:valueText:isExpanded:content:)")
        }

        // MARK: - Setup

        private func setup() {
            backgroundColor = .clear

            addSubview(headerButton)
            headerButton.snp.makeConstraints {
                $0.top.leading.trailing.equalToSuperview()
                $0.height.equalTo(44)
            }
            headerButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.isExpanded.toggle()
                self.onToggle?(self.isExpanded)
            }, for: .touchUpInside)

            symbolView.image = UIImage(systemName: symbolName)
            symbolView.tintColor = .white
            symbolView.contentMode = .center
            headerButton.addSubview(symbolView)
            symbolView.snp.makeConstraints {
                $0.leading.equalToSuperview().offset(12)
                $0.centerY.equalToSuperview()
                $0.size.equalTo(CGSize(width: 22, height: 22))
            }

            titleLabel.text = title
            titleLabel.textColor = .white
            titleLabel.font = titleFont
            headerButton.addSubview(titleLabel)
            titleLabel.snp.makeConstraints {
                $0.leading.equalTo(symbolView.snp.trailing).offset(10)
                $0.centerY.equalToSuperview()
            }

            valueLabel.text = valueText
            valueLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            valueLabel.font = valueFont
            valueLabel.textAlignment = .right
            headerButton.addSubview(valueLabel)

            chevronView.image = UIImage(systemName: "chevron.down")
            chevronView.tintColor = UIColor.white.withAlphaComponent(0.6)
            chevronView.contentMode = .center
            headerButton.addSubview(chevronView)
            chevronView.snp.makeConstraints {
                $0.trailing.equalToSuperview().offset(-12)
                $0.centerY.equalToSuperview()
                $0.size.equalTo(CGSize(width: 18, height: 18))
            }
            valueLabel.snp.makeConstraints {
                $0.trailing.equalTo(chevronView.snp.leading).offset(-8)
                $0.centerY.equalToSuperview()
                $0.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(8)
            }

            addSubview(contentContainer)
            contentContainer.clipsToBounds = true
            contentContainer.snp.makeConstraints {
                $0.top.equalTo(headerButton.snp.bottom)
                $0.leading.trailing.equalToSuperview()
                $0.bottom.equalToSuperview()
            }
            contentContainer.addSubview(contentView)
            contentView.snp.makeConstraints {
                $0.leading.equalToSuperview().offset(12)
                $0.trailing.equalToSuperview().offset(-12)
                $0.top.equalToSuperview().offset(2)
                $0.bottom.equalToSuperview().offset(-10)
            }

            // Transparent control overlay above `contentView` — only enabled when the row
            // is disabled. Intercepts taps so the underlying slider/segmented don't react,
            // forwards them to `onDisabledTap` for the host VC to surface a toast.
            contentContainer.addSubview(disabledOverlay)
            disabledOverlay.snp.makeConstraints { $0.edges.equalTo(contentView) }
            disabledOverlay.isHidden = true
            disabledOverlay.backgroundColor = .clear
            disabledOverlay.addAction(UIAction { [weak self] _ in
                guard let self, let disabledMessage else { return }
                onDisabledTap?(disabledMessage)
            }, for: .touchUpInside)

            applyExpansion(animated: false)
        }

        private func applyExpansion(animated: Bool) {
            let block: () -> Void = { [self] in
                contentContainer.alpha = isExpanded ? 1 : 0
                contentContainer.isHidden = !isExpanded
                chevronView.transform = isExpanded
                    ? CGAffineTransform(rotationAngle: .pi)
                    : .identity
            }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.2, animations: block)
            } else {
                block()
            }
        }
    }
#endif
