import PrismCore
import SnapKit
import UIKit

// MARK: - PermissionsViewController

/// Dark-themed permissions flow for camera + microphone.
final class PermissionsViewController: UIViewController {
    private let cameraCard = PermissionCard(title: "Camera", symbol: "camera")
    private let micCard = PermissionCard(title: "Microphone", symbol: "microphone")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Permissions"
        view.backgroundColor = .systemBackground

        let stack = UIStackView(arrangedSubviews: [cameraCard, micCard])
        stack.axis = .vertical
        stack.spacing = 16
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.isLayoutMarginsRelativeArrangement = true

        let scrollView = UIScrollView()
        view.addSubview(scrollView)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
        scrollView.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview()
            $0.width.equalToSuperview()
        }

        let openSettings = UIButton(configuration: .gray())
        openSettings.setTitle("Open System Settings", for: .normal)
        openSettings.addAction(UIAction { [weak self] _ in self?.openSystemSettings() }, for: .touchUpInside)
        stack.addArrangedSubview(openSettings)

        let footer = UILabel()
        footer.text = "Camera and microphone permissions persist; you can revoke them in Settings."
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0
        stack.addArrangedSubview(footer)

        cameraCard.onRequest = { [weak self] in self?.requestCamera() }
        micCard.onRequest = { [weak self] in self?.requestMicrophone() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    // MARK: - Actions

    private func requestCamera() {
        Task {
            _ = await PRMPermissions.requestCameraAccess()
            refresh()
        }
    }

    private func requestMicrophone() {
        Task {
            _ = await PRMPermissions.requestMicrophoneAccess()
            refresh()
        }
    }

    private func openSystemSettings() {
        guard let url = PRMPermissions.settingsURL() else { return }
        UIApplication.shared.open(url)
    }

    private func refresh() {
        cameraCard.apply(status: PRMPermissions.cameraStatus())
        micCard.apply(status: PRMPermissions.microphoneStatus())
    }
}

// MARK: - PermissionCard

private final class PermissionCard: UIView {
    var onRequest: (() -> Void)?

    private let titleLabel = UILabel()
    private let symbolView = UIImageView()
    private let statusPill = StatusPillView()
    private let requestButton = UIButton(configuration: .filled())

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous

        symbolView.image = UIImage(systemName: symbol)
        symbolView.tintColor = .systemYellow
        symbolView.contentMode = .scaleAspectFit

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title3).bold()

        var config = UIButton.Configuration.filled()
        config.title = "Request Access"
        config.baseBackgroundColor = .systemYellow
        config.baseForegroundColor = .black
        requestButton.configuration = config
        requestButton.addAction(UIAction { [weak self] _ in self?.onRequest?() }, for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [symbolView, titleLabel, statusPill])
        topRow.alignment = .center
        topRow.spacing = 12

        symbolView.snp.makeConstraints { $0.size.equalTo(32) }
        statusPill.snp.makeConstraints { $0.width.equalTo(100) }
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [topRow, requestButton])
        stack.axis = .vertical
        stack.spacing = 16
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(20) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(title:symbol:) instead")
    }

    func apply(status: PRMPermissions.Status) {
        statusPill.apply(status: status)
        requestButton.isHidden = status != .notDetermined
    }
}

// MARK: - StatusPillView

private final class StatusPillView: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.font = .preferredFont(forTextStyle: .caption1).bold()
        label.textAlignment = .center
        addSubview(label)
        label.snp.makeConstraints {
            $0.top.bottom.equalToSuperview().inset(6)
            $0.centerX.equalToSuperview()
            $0.leading.greaterThanOrEqualToSuperview().offset(12)
            $0.trailing.lessThanOrEqualToSuperview().offset(-12)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init() instead")
    }

    func apply(status: PRMPermissions.Status) {
        switch status {
        case .authorized:
            label.text = "Authorized"
            label.textColor = .systemGreen
            backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
        case .denied:
            label.text = "Denied"
            label.textColor = .systemRed
            backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
        case .restricted:
            label.text = "Restricted"
            label.textColor = .systemOrange
            backgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
        case .notDetermined:
            label.text = "Not Set"
            label.textColor = .secondaryLabel
            backgroundColor = UIColor.secondarySystemFill
        }
    }
}

// MARK: - UIFont bold helper

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
