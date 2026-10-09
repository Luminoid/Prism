import PrismCore
import SnapKit
import UIKit

// MARK: - ExampleFont

/// Fonts that follow Dynamic Type. Camera chrome passes a `maximum` so the largest text
/// sizes can't push the viewfinder controls off screen.
enum ExampleFont {
    static func scaled(
        _ size: CGFloat,
        weight: UIFont.Weight = .regular,
        style: UIFont.TextStyle = .body,
        maximum: CGFloat? = nil
    ) -> UIFont {
        scale(.systemFont(ofSize: size, weight: weight), style: style, maximum: maximum)
    }

    static func monospaced(
        _ size: CGFloat,
        weight: UIFont.Weight = .regular,
        style: UIFont.TextStyle = .body,
        maximum: CGFloat? = nil
    ) -> UIFont {
        scale(.monospacedSystemFont(ofSize: size, weight: weight), style: style, maximum: maximum)
    }

    private static func scale(_ font: UIFont, style: UIFont.TextStyle, maximum: CGFloat?) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        guard let maximum else { return metrics.scaledFont(for: font) }
        return metrics.scaledFont(for: font, maximumPointSize: maximum)
    }
}

// MARK: - PaddedLabel

/// Text on a rounded chip (12pt continuous corners) with padding around it: Studio's
/// telemetry and recording timer, the toasts, and every demo's status chip. Wraps when
/// `numberOfLines` allows it.
final class PaddedLabel: UILabel {
    // MARK: - Properties

    var insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12) {
        didSet { invalidateIntrinsicContentSize() }
    }

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init() instead")
    }

    // MARK: - Layout

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let textBounds = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return textBounds.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}

// MARK: - SectionHeaderLabel

/// The demos' one section-header style: small bold capitals in secondary white, marked as a
/// header so VoiceOver's rotor can jump between sections.
final class SectionHeaderLabel: UILabel {
    init(_ title: String) {
        super.init(frame: .zero)
        text = title.uppercased()
        font = ExampleFont.scaled(11, weight: .bold, style: .caption1)
        adjustsFontForContentSizeCategory = true
        textColor = UIColor.white.withAlphaComponent(0.6)
        accessibilityTraits = .header
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(_:) instead")
    }
}

// MARK: - ToastPresenter

/// The demos' shared feedback path: one toast at a time, announced to VoiceOver, and
/// ``report(_:context:)`` for errors, which logs the error in full and toasts a short message.
/// Settings that can't be on together go through ``gaveWay(_:)`` (the newest turned others
/// off) and ``refused(_:because:)``, each with one log line.
@MainActor
final class ToastPresenter {
    // MARK: - Properties

    private weak var hostView: UIView?
    private let anchor: ConstraintItem
    private var toast: PaddedLabel?
    private var dismissTask: Task<Void, Never>?

    // MARK: - Init

    /// Toasts appear centered in `hostView`, 12pt below `anchor`.
    init(hostView: UIView, below anchor: ConstraintItem) {
        self.hostView = hostView
        self.anchor = anchor
    }

    deinit {
        dismissTask?.cancel()
    }

    // MARK: - Showing

    /// Shows `message` long enough to read (two seconds, longer for long messages),
    /// replacing a toast that's still up. The same message again only keeps it up, so a
    /// slider drag doesn't re-announce it on every tick.
    func show(_ message: String) {
        let isRepeat = toast?.text == message
        if !isRepeat {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        guard let label = toast ?? makeToast() else { return }
        label.text = message
        dismissTask?.cancel()
        let duration = Self.readingDuration(of: message)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Logs and toasts what a setting turned off (or on) to take effect. Nothing when it
    /// changed nothing.
    func gaveWay(_ change: SettingChange) {
        guard !change.isEmpty else { return }
        ExampleLog.ui.notice("\(change.logLine, privacy: .public)")
        show(change.message)
    }

    /// Logs and toasts why `setting` was refused; `message` is the toast ("Stop recording to
    /// change ISO.").
    func refused(_ setting: String, because message: String) {
        ExampleLog.ui.notice("Refused: \(setting, privacy: .public) (\(message, privacy: .public))")
        show(message)
    }

    /// Logs `error` under the Example's UI category and toasts "<context> failed: …", or for
    /// a setting the camera can't take right now, "Not available: <reason>".
    func report(_ error: any Error, context: String) {
        let described = PRMLog.describe(error)
        ExampleLog.ui.error("\(context, privacy: .public) failed: \(described.summary, privacy: .public)")
        if let detail = described.detail {
            ExampleLog.ui.debug("\(context, privacy: .public) error detail: \(detail, privacy: .private)")
        }
        if case let .unsupportedConfiguration(reason) = error as? PRMSessionError {
            show("Not available: \(reason)")
        } else {
            show("\(context) failed: \(error.localizedDescription)")
        }
    }

    /// Two seconds, plus one per 50 characters past the first 50, up to five.
    static func readingDuration(of message: String) -> Duration {
        let extra = max(0, message.count - 50) / 50
        return .seconds(min(5, 2 + extra))
    }

    // MARK: - Helpers

    private func makeToast() -> PaddedLabel? {
        guard let hostView else { return nil }
        let label = PaddedLabel()
        label.textColor = .white
        label.font = ExampleFont.scaled(13, weight: .medium, style: .footnote, maximum: 22)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.textAlignment = .center
        label.numberOfLines = 0
        hostView.addSubview(label)
        label.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.top.equalTo(anchor).offset(12)
            $0.width.lessThanOrEqualToSuperview().offset(-32)
        }
        toast = label
        return label
    }

    private func dismiss() {
        guard let label = toast else { return }
        toast = nil
        UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }, completion: { _ in
            label.removeFromSuperview()
        })
    }
}
