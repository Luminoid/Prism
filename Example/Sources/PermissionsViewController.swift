import AVFoundation
import PrismCore
import SnapKit
import UIKit

// MARK: - PermissionsViewController

/// Demonstrates `PRMPermissionHelper` (camera/mic status, request, settingsURL)
/// and `PRMSessionSetupResult` (authorization flow).
final class PermissionsViewController: UIViewController {
    // MARK: - Properties

    private let cameraStatusLabel = UILabel()
    private let micStatusLabel = UILabel()
    private let sessionResultLabel = UILabel()
    private let requestCameraButton = UIButton(type: .system)
    private let requestMicButton = UIButton(type: .system)
    private let setupSessionButton = UIButton(type: .system)
    private let openSettingsButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Permissions"
        view.backgroundColor = .systemBackground
        setupUI()
        refreshStatuses()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatuses()
    }

    // MARK: - Setup

    private func setupUI() {
        let scrollView = UIScrollView()
        view.addSubview(scrollView)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        stack.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview()
            $0.width.equalToSuperview()
        }

        // Camera section
        let cameraCard = makeCard(
            title: "Camera Permission",
            statusLabel: cameraStatusLabel,
            button: requestCameraButton,
            action: #selector(requestCamera),
        )
        stack.addArrangedSubview(cameraCard)

        // Microphone section
        let micCard = makeCard(
            title: "Microphone Permission",
            statusLabel: micStatusLabel,
            button: requestMicButton,
            action: #selector(requestMicrophone),
        )
        stack.addArrangedSubview(micCard)

        // Session setup section
        let sessionCard = makeSessionCard()
        stack.addArrangedSubview(sessionCard)

        // Open Settings
        openSettingsButton.setTitle("Open App Settings", for: .normal)
        openSettingsButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        openSettingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        stack.addArrangedSubview(openSettingsButton)

        // Info text
        let infoLabel = UILabel()
        infoLabel.text = """
        This screen demonstrates PRMPermissionHelper and PRMSessionSetupResult. \
        Camera and microphone permissions must be granted before starting a capture session.
        """
        infoLabel.font = .systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabel
        infoLabel.numberOfLines = 0
        stack.addArrangedSubview(infoLabel)
    }

    private func makeCard(
        title: String,
        statusLabel: UILabel,
        button: UIButton,
        action: Selector,
    ) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        statusLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .right

        button.setTitle("Request Access", for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        topRow.distribution = .equalSpacing

        let stack = UIStackView(arrangedSubviews: [topRow, button])
        stack.axis = .vertical
        stack.spacing = 12

        card.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }

        return card
    }

    private func makeSessionCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12

        let titleLabel = UILabel()
        titleLabel.text = "Session Setup"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        sessionResultLabel.text = "Not tested"
        sessionResultLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        sessionResultLabel.textColor = .secondaryLabel
        sessionResultLabel.textAlignment = .right

        setupSessionButton.setTitle("Test Session Setup", for: .normal)
        setupSessionButton.addTarget(self, action: #selector(testSessionSetup), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, sessionResultLabel])
        topRow.distribution = .equalSpacing

        let stack = UIStackView(arrangedSubviews: [topRow, setupSessionButton])
        stack.axis = .vertical
        stack.spacing = 12

        card.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }

        return card
    }

    // MARK: - Actions

    @objc private func requestCamera() {
        Task {
            _ = await PRMPermissionHelper.requestCameraAccess()
            refreshStatuses()
        }
    }

    @objc private func requestMicrophone() {
        Task {
            _ = await PRMPermissionHelper.requestMicrophoneAccess()
            refreshStatuses()
        }
    }

    @objc private func testSessionSetup() {
        let sm = PRMCameraSessionManager()
        sm.sessionQueue.async { [weak self] in
            sm.checkAuthorization()
            sm.configureSession(with: PRMCameraConfiguration())
            let result = sm.setupResult
            sm.stopSession()
            DispatchQueue.main.async {
                self?.displaySessionResult(result)
            }
        }
    }

    @objc private func openSettings() {
        guard let url = PRMPermissionHelper.settingsURL() else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - UI Updates

    private func refreshStatuses() {
        let cameraStatus = PRMPermissionHelper.cameraStatus()
        let micStatus = PRMPermissionHelper.microphoneStatus()

        cameraStatusLabel.text = statusText(cameraStatus)
        cameraStatusLabel.textColor = statusColor(cameraStatus)
        requestCameraButton.isEnabled = cameraStatus == .notDetermined

        micStatusLabel.text = statusText(micStatus)
        micStatusLabel.textColor = statusColor(micStatus)
        requestMicButton.isEnabled = micStatus == .notDetermined
    }

    private func displaySessionResult(_ result: PRMSessionSetupResult) {
        switch result {
        case .success:
            sessionResultLabel.text = "Success"
            sessionResultLabel.textColor = .systemGreen
        case .notAuthorized:
            sessionResultLabel.text = "Not Authorized"
            sessionResultLabel.textColor = .systemRed
        case .configurationFailed:
            sessionResultLabel.text = "Config Failed"
            sessionResultLabel.textColor = .systemOrange
        }
    }

    private func statusText(_ status: PRMPermissionHelper.PermissionStatus) -> String {
        switch status {
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not Determined"
        }
    }

    private func statusColor(_ status: PRMPermissionHelper.PermissionStatus) -> UIColor {
        switch status {
        case .authorized: .systemGreen
        case .denied: .systemRed
        case .restricted: .systemOrange
        case .notDetermined: .secondaryLabel
        }
    }
}
