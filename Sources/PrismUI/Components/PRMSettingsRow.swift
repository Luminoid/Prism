#if canImport(UIKit)
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
            didSet {
                titleLabel.text = title
                updateHeaderAccessibility()
            }
        }

        public var valueText: String? {
            didSet {
                valueLabel.text = valueText
                updateHeaderAccessibility()
            }
        }

        public var symbolName: String {
            didSet { symbolView.image = UIImage(systemName: symbolName) }
        }

        public var isExpanded: Bool {
            didSet {
                applyExpansion(animated: true)
                updateHeaderAccessibility()
            }
        }

        /// Title font at the default text size; it scales with Dynamic Type. Override to match
        /// the host app's type ramp.
        public var titleFont: UIFont = .systemFont(ofSize: 13, weight: .semibold) {
            didSet { titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: titleFont) }
        }

        /// Value-label font at the default text size, scaled with Dynamic Type. Defaults to a
        /// monospaced digit font for tabular numerics.
        public var valueFont: UIFont = .monospacedSystemFont(ofSize: 11, weight: .medium) {
            didSet { valueLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: valueFont) }
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
            // VoiceOver reads the explanation instead of controls that can't be used.
            contentView.accessibilityElementsHidden = isContentDisabled
            disabledOverlay.isHidden = !isContentDisabled
            disabledOverlay.accessibilityLabel = message
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

            headerButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(headerButton)
            // At least 44pt (the HIG minimum target), taller when Dynamic Type grows the title.
            let preferredHeight = headerButton.heightAnchor.constraint(equalToConstant: 44)
            preferredHeight.priority = .defaultLow
            NSLayoutConstraint.activate([
                headerButton.topAnchor.constraint(equalTo: topAnchor),
                headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                headerButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                preferredHeight,
            ])
            headerButton.isAccessibilityElement = true
            headerButton.accessibilityTraits = .button
            headerButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.isExpanded.toggle()
                self.onToggle?(self.isExpanded)
            }, for: .touchUpInside)

            symbolView.image = UIImage(systemName: symbolName)
            symbolView.tintColor = .white
            symbolView.contentMode = .center
            symbolView.translatesAutoresizingMaskIntoConstraints = false
            headerButton.addSubview(symbolView)
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor, constant: 12),
                symbolView.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
                symbolView.widthAnchor.constraint(equalToConstant: 22),
                symbolView.heightAnchor.constraint(equalToConstant: 22),
            ])

            titleLabel.text = title
            titleLabel.textColor = .white
            titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: titleFont)
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            headerButton.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 10),
                titleLabel.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: headerButton.topAnchor, constant: 8),
                titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerButton.bottomAnchor, constant: -8),
            ])

            valueLabel.text = valueText
            valueLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            valueLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: valueFont)
            valueLabel.adjustsFontForContentSizeCategory = true
            valueLabel.textAlignment = .right
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            headerButton.addSubview(valueLabel)

            chevronView.image = UIImage(systemName: "chevron.down")
            chevronView.tintColor = UIColor.white.withAlphaComponent(0.6)
            chevronView.contentMode = .center
            chevronView.translatesAutoresizingMaskIntoConstraints = false
            headerButton.addSubview(chevronView)
            NSLayoutConstraint.activate([
                chevronView.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: -12),
                chevronView.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
                chevronView.widthAnchor.constraint(equalToConstant: 18),
                chevronView.heightAnchor.constraint(equalToConstant: 18),
            ])
            NSLayoutConstraint.activate([
                valueLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
                valueLabel.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
                valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            ])

            contentContainer.clipsToBounds = true
            contentContainer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentContainer)
            NSLayoutConstraint.activate([
                contentContainer.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
                contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 12),
                contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12),
                contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 2),
                contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -10),
            ])

            // Transparent control overlay above `contentView` — only enabled when the row
            // is disabled. Intercepts taps so the underlying slider/segmented don't react,
            // forwards them to `onDisabledTap` for the host VC to surface a toast.
            disabledOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(disabledOverlay)
            NSLayoutConstraint.activate([
                disabledOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
                disabledOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                disabledOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                disabledOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            disabledOverlay.isHidden = true
            disabledOverlay.backgroundColor = .clear
            disabledOverlay.isAccessibilityElement = true
            disabledOverlay.accessibilityTraits = .staticText
            disabledOverlay.addAction(UIAction { [weak self] _ in
                guard let self, let disabledMessage else { return }
                onDisabledTap?(disabledMessage)
            }, for: .touchUpInside)

            applyExpansion(animated: false)
            updateHeaderAccessibility()
        }

        /// The header reads as a button: the title, then the value and whether the row is
        /// expanded.
        private func updateHeaderAccessibility() {
            headerButton.accessibilityLabel = title
            let state = isExpanded
                ? String(localized: "Expanded", bundle: .module)
                : String(localized: "Collapsed", bundle: .module)
            headerButton.accessibilityValue = [valueText, state]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: ", ")
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
