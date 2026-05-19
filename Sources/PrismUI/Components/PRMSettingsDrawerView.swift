#if canImport(UIKit)
    import SnapKit
    import UIKit

    /// A slide-in side drawer that hosts a vertically-scrolling stack of settings.
    ///
    /// Layout is fully managed: callers `setOpen(_:animated:)` to show/hide, and
    /// `appendSection(title:rows:)` / `addRow(_:)` to populate. Designed to dock to the
    /// trailing edge of the camera screen without obstructing the preview center.
    public final class PRMSettingsDrawerView: UIView {
        // MARK: - Configuration

        /// Width of the drawer when open. Defaults to 280pt.
        public var drawerWidth: CGFloat = 280

        /// Whether the drawer is currently open.
        public private(set) var isOpen: Bool = false

        /// Translucent backdrop dimming the camera preview when open. Tap to dismiss.
        public var dimsBackdrop: Bool = true

        /// Title font. Override to match the host app's type ramp.
        public var titleFont: UIFont = .systemFont(ofSize: 16, weight: .bold) {
            didSet { titleLabel.font = titleFont }
        }

        /// Section-header font.
        public var sectionHeaderFont: UIFont = .systemFont(ofSize: 10, weight: .heavy) {
            didSet { restyleSectionHeaders() }
        }

        public var onClose: (() -> Void)?

        // MARK: - Subviews

        private let backdropView = UIView()
        private let containerView = UIView()
        private let scrollView = UIScrollView()
        private let stackView = UIStackView()
        private let titleLabel = UILabel()
        private let closeButton = UIButton(type: .system)

        private var containerTrailingConstraint: Constraint?

        // MARK: - Init

        public init(title: String = "Camera") {
            super.init(frame: .zero)
            setup(title: title)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Use init(title:)")
        }

        // MARK: - Setup

        private func setup(title: String) {
            isUserInteractionEnabled = true
            backgroundColor = .clear

            addSubview(backdropView)
            backdropView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            backdropView.alpha = 0
            backdropView.snp.makeConstraints { $0.edges.equalToSuperview() }
            let backdropTap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
            backdropView.addGestureRecognizer(backdropTap)

            addSubview(containerView)
            containerView.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            containerView.layer.cornerRadius = 16
            containerView.layer.cornerCurve = .continuous
            containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            containerView.clipsToBounds = true
            containerView.snp.makeConstraints {
                $0.top.bottom.equalToSuperview()
                $0.width.equalTo(drawerWidth)
                containerTrailingConstraint = $0.leading.equalTo(snp.trailing).constraint
            }

            titleLabel.text = title
            titleLabel.textColor = .white
            titleLabel.font = titleFont
            containerView.addSubview(titleLabel)
            titleLabel.snp.makeConstraints {
                $0.top.equalTo(containerView.safeAreaLayoutGuide).offset(16)
                $0.leading.equalToSuperview().offset(16)
            }

            // 44×44 hit target per HIG; the 28pt glyph stays visually centered via
            // UIButton.Configuration's content insets (the old `contentEdgeInsets` API is
            // deprecated when any UIButton in the process opts into UIButton.Configuration).
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "xmark.circle.fill")
            config.baseForegroundColor = UIColor.white.withAlphaComponent(0.7)
            let inset: CGFloat = (44 - 28) / 2
            config.contentInsets = NSDirectionalEdgeInsets(
                top: inset, leading: inset, bottom: inset, trailing: inset
            )
            closeButton.configuration = config
            containerView.addSubview(closeButton)
            closeButton.snp.makeConstraints {
                $0.centerY.equalTo(titleLabel)
                $0.trailing.equalToSuperview().offset(-4)
                $0.size.equalTo(CGSize(width: 44, height: 44))
            }
            closeButton.addAction(UIAction { [weak self] _ in
                self?.setOpen(false, animated: true)
                self?.onClose?()
            }, for: .touchUpInside)

            containerView.addSubview(scrollView)
            scrollView.showsVerticalScrollIndicator = false
            scrollView.snp.makeConstraints {
                $0.top.equalTo(titleLabel.snp.bottom).offset(8)
                $0.leading.trailing.equalToSuperview()
                $0.bottom.equalTo(containerView.safeAreaLayoutGuide)
            }

            stackView.axis = .vertical
            stackView.spacing = 4
            stackView.alignment = .fill
            stackView.distribution = .fill
            scrollView.addSubview(stackView)
            stackView.snp.makeConstraints {
                $0.edges.equalToSuperview()
                $0.width.equalToSuperview()
            }
        }

        // MARK: - Open / close

        public func setOpen(_ open: Bool, animated: Bool) {
            guard open != isOpen else { return }
            isOpen = open
            isUserInteractionEnabled = open
            containerTrailingConstraint?.update(offset: open ? -drawerWidth : 0)
            let block: () -> Void = { [self] in
                superview?.layoutIfNeeded()
                backdropView.alpha = (open && dimsBackdrop) ? 1 : 0
            }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    usingSpringWithDamping: 0.9,
                    initialSpringVelocity: 0,
                    options: .curveEaseOut,
                    animations: block
                )
            } else {
                block()
            }
        }

        @objc private func handleBackdropTap() {
            setOpen(false, animated: true)
            onClose?()
        }

        // MARK: - Population

        /// Adds a section header label followed by the given rows.
        public func appendSection(title: String, rows: [PRMSettingsRow]) {
            let header = SectionHeader(title: title, font: sectionHeaderFont)
            stackView.addArrangedSubview(header)
            for row in rows {
                stackView.addArrangedSubview(row)
            }
        }

        /// Adds a single row to the existing stack (no section header).
        public func addRow(_ row: PRMSettingsRow) {
            stackView.addArrangedSubview(row)
        }

        /// Removes every section and row.
        public func clear() {
            // Iterate a snapshot, not the live array — `removeFromSuperview()` mutates
            // `arrangedSubviews` automatically (UIStackView observes view removal).
            for view in Array(stackView.arrangedSubviews) {
                view.removeFromSuperview()
            }
        }

        private func restyleSectionHeaders() {
            for view in stackView.arrangedSubviews {
                guard let header = view as? SectionHeader else { continue }
                header.applyFont(sectionHeaderFont)
            }
        }
    }

    // MARK: - SectionHeader

    private final class SectionHeader: UIView {
        private let label = UILabel()

        init(title: String, font: UIFont) {
            super.init(frame: .zero)
            label.text = title.uppercased()
            label.textColor = UIColor.white.withAlphaComponent(0.55)
            label.font = font
            label.letterSpacing = 1.2
            addSubview(label)
            label.snp.makeConstraints {
                $0.leading.equalToSuperview().offset(16)
                $0.trailing.equalToSuperview().offset(-16)
                $0.top.equalToSuperview().offset(12)
                $0.bottom.equalToSuperview().offset(-4)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Use init(title:font:)")
        }

        func applyFont(_ font: UIFont) {
            label.font = font
        }
    }

    private extension UILabel {
        var letterSpacing: CGFloat {
            get { 0 }
            set {
                guard let current = text else { return }
                attributedText = NSAttributedString(
                    string: current,
                    attributes: [.kern: newValue]
                )
            }
        }
    }
#endif
