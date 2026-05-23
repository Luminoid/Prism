#if canImport(UIKit)
    import UIKit

    /// A slide-in side drawer that hosts a vertically-scrolling stack of settings.
    ///
    /// Layout is fully managed: callers `setOpen(_:animated:)` to show/hide, and
    /// `appendSection(title:rows:)` / `addRow(_:)` to populate. Designed to dock to the
    /// trailing edge of the camera screen without obstructing the preview center.
    public final class PRMSettingsDrawerView: UIView {
        // MARK: - Configuration

        /// Width of the drawer when open. Defaults to 280pt.
        public var drawerWidth: CGFloat = 280 {
            didSet {
                containerWidthConstraint?.constant = drawerWidth
                containerTrailingConstraint?.constant = isOpen ? -drawerWidth : 0
            }
        }

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

        /// Drives the slide-in animation. Container's `leading` is pinned to the
        /// drawer's `trailing` plus this constant — `0` parks it off-screen, `-drawerWidth`
        /// slides it on.
        private var containerTrailingConstraint: NSLayoutConstraint?
        private var containerWidthConstraint: NSLayoutConstraint?

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
            backdropView.translatesAutoresizingMaskIntoConstraints = false
            backdropView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            backdropView.alpha = 0
            NSLayoutConstraint.activate([
                backdropView.topAnchor.constraint(equalTo: topAnchor),
                backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
                backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
                backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            let backdropTap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
            backdropView.addGestureRecognizer(backdropTap)

            addSubview(containerView)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            containerView.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            containerView.layer.cornerRadius = 16
            containerView.layer.cornerCurve = .continuous
            containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            containerView.clipsToBounds = true
            let trailing = containerView.leadingAnchor.constraint(equalTo: trailingAnchor)
            let width = containerView.widthAnchor.constraint(equalToConstant: drawerWidth)
            containerTrailingConstraint = trailing
            containerWidthConstraint = width
            NSLayoutConstraint.activate([
                containerView.topAnchor.constraint(equalTo: topAnchor),
                containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                width,
                trailing,
            ])

            titleLabel.text = title
            titleLabel.textColor = .white
            titleLabel.font = titleFont
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor, constant: 16),
                titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            ])

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
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -4),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44),
            ])
            closeButton.addAction(UIAction { [weak self] _ in
                self?.setOpen(false, animated: true)
                self?.onClose?()
            }, for: .touchUpInside)

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.showsVerticalScrollIndicator = false
            containerView.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor),
            ])

            stackView.axis = .vertical
            stackView.spacing = 4
            stackView.alignment = .fill
            stackView.distribution = .fill
            stackView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            ])
        }

        // MARK: - Open / close

        public func setOpen(_ open: Bool, animated: Bool) {
            guard open != isOpen else { return }
            isOpen = open
            isUserInteractionEnabled = open
            containerTrailingConstraint?.constant = open ? -drawerWidth : 0
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
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
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
