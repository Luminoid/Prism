@preconcurrency import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - ConfigurationLabViewController

/// Exposes every knob on `PRMCameraConfiguration` so the user can build a configuration, then
/// "Apply" it to a live preview. Demonstrates `PRMCamera.configure(_:)` re-runs and the
/// various session-level toggles that the DSLR Studio leaves at defaults.
///
/// Covered:
/// - `sessionPreset` picker (photo, hd1280x720, hd1920x1080, hd4K3840x2160, high, medium, low),
/// - `cameraPosition` picker (back, front),
/// - `deviceTypes` picker (default order, triple-only, wide-only, dual-wide-only),
/// - `videoPixelFormat` picker (32BGRA, 420YpCbCr8BiPlanarVideoRange, 420YpCbCr8BiPlanarFullRange),
/// - `includesAudio`, `includesVideoDataOutput`, `includesPhotoOutput`, `includesMovieFileOutput`,
/// - `maxPhotoQualityPrioritization`,
/// - `enableResponsiveCapture`, `enableAutoDeferredPhotoDelivery`, `enableZeroShutterLag`,
/// - `enableLivePhoto`, `enableDepthDataDelivery`, `enablePortraitEffectsMatteDelivery`,
/// - `preferredVideoStabilizationMode`,
/// - `enableMultitaskingCameraAccess`.
///
/// After Apply, the result is reflected in the status panel (which features negotiated, which
/// were silently downgraded due to device caps).
@MainActor
final class ConfigurationLabViewController: UIViewController {
    // MARK: - State

    private var configuration = PRMCameraConfiguration()
    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    private let renderContext: PRMRenderContext = {
        guard let context = PRMRenderContext(name: "ConfigLab") else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var previewView = PRMPreviewView(context: renderContext)

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusLabel = UILabel()
    private let applyButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = "Configuration Lab"
        setupLayout()
        populateContent()
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await camera.stop() }
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(previewView)
        previewView.rotation = .rotate90
        previewView.contentFit = .fill
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.35)
        }

        statusLabel.text = "Ready. Pick a configuration below, then Apply."
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom).offset(8)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
        }

        var applyConfig = UIButton.Configuration.filled()
        applyConfig.title = "Apply Configuration"
        applyConfig.baseBackgroundColor = .systemYellow
        applyConfig.baseForegroundColor = .black
        applyConfig.cornerStyle = .large
        applyButton.configuration = applyConfig
        applyButton.addAction(UIAction { [weak self] _ in self?.applyConfiguration() }, for: .touchUpInside)
        view.addSubview(applyButton)
        applyButton.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
            $0.height.equalTo(44)
        }

        view.addSubview(scrollView)
        scrollView.snp.makeConstraints {
            $0.top.equalTo(statusLabel.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview()
            $0.bottom.equalTo(applyButton.snp.top).offset(-8)
        }
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)
        contentStack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
            $0.width.equalToSuperview().offset(-32)
        }
    }

    // MARK: - Form

    private func populateContent() {
        addPicker(
            title: "Session preset",
            options: SessionPresetOption.allCases,
            current: { [unowned self] in
                SessionPresetOption.allCases.firstIndex(where: { $0.preset == configuration.sessionPreset }) ?? 0
            },
            apply: { [unowned self] index in
                configuration.sessionPreset = SessionPresetOption.allCases[index].preset
            }
        )
        addPicker(
            title: "Camera position",
            options: PositionOption.allCases,
            current: { [unowned self] in
                PositionOption.allCases.firstIndex(where: { $0.position == configuration.cameraPosition }) ?? 0
            },
            apply: { [unowned self] index in
                configuration.cameraPosition = PositionOption.allCases[index].position
            }
        )
        addPicker(
            title: "Device types",
            options: DeviceTypeOption.allCases,
            current: { 0 },
            apply: { [unowned self] index in
                configuration.deviceTypes = DeviceTypeOption.allCases[index].types
            }
        )
        addPicker(
            title: "Video pixel format",
            options: PixelFormatOption.allCases,
            current: { [unowned self] in
                PixelFormatOption.allCases.firstIndex(where: { $0.value == configuration.videoPixelFormat }) ?? 0
            },
            apply: { [unowned self] index in
                configuration.videoPixelFormat = PixelFormatOption.allCases[index].value
            }
        )
        addPicker(
            title: "Photo quality ceiling",
            options: QualityOption.allCases,
            current: { [unowned self] in
                QualityOption.allCases.firstIndex(where: { $0.value == configuration.maxPhotoQualityPrioritization }) ?? 2
            },
            apply: { [unowned self] index in
                configuration.maxPhotoQualityPrioritization = QualityOption.allCases[index].value
            }
        )
        addPicker(
            title: "Preferred stabilization",
            options: StabilizationOption.allCases,
            current: { [unowned self] in
                StabilizationOption.allCases.firstIndex(where: { $0.value == configuration.preferredVideoStabilizationMode }) ?? 0
            },
            apply: { [unowned self] index in
                configuration.preferredVideoStabilizationMode = StabilizationOption.allCases[index].value
            }
        )

        addToggle(
            title: "Include audio input",
            initial: configuration.includesAudio,
            apply: { [unowned self] in configuration.includesAudio = $0 }
        )
        addToggle(
            title: "Video data output (filters)",
            initial: configuration.includesVideoDataOutput,
            apply: { [unowned self] in configuration.includesVideoDataOutput = $0 }
        )
        addToggle(
            title: "Photo output",
            initial: configuration.includesPhotoOutput,
            apply: { [unowned self] in configuration.includesPhotoOutput = $0 }
        )
        addToggle(
            title: "Movie file output",
            initial: configuration.includesMovieFileOutput,
            apply: { [unowned self] in configuration.includesMovieFileOutput = $0 }
        )
        addToggle(
            title: "Responsive capture (iOS 17+)",
            initial: configuration.enableResponsiveCapture,
            apply: { [unowned self] in configuration.enableResponsiveCapture = $0 }
        )
        addToggle(
            title: "Auto-deferred photo delivery",
            initial: configuration.enableAutoDeferredPhotoDelivery,
            apply: { [unowned self] in configuration.enableAutoDeferredPhotoDelivery = $0 }
        )
        addToggle(
            title: "Zero shutter lag",
            initial: configuration.enableZeroShutterLag,
            apply: { [unowned self] in configuration.enableZeroShutterLag = $0 }
        )
        addToggle(
            title: "Live Photo capture",
            initial: configuration.enableLivePhoto,
            apply: { [unowned self] in configuration.enableLivePhoto = $0 }
        )
        addToggle(
            title: "Depth-data delivery",
            initial: configuration.enableDepthDataDelivery,
            apply: { [unowned self] in configuration.enableDepthDataDelivery = $0 }
        )
        addToggle(
            title: "Portrait-effects matte",
            initial: configuration.enablePortraitEffectsMatteDelivery,
            apply: { [unowned self] in configuration.enablePortraitEffectsMatteDelivery = $0 }
        )
        addToggle(
            title: "Multitasking camera access (iPad)",
            initial: configuration.enableMultitaskingCameraAccess,
            apply: { [unowned self] in configuration.enableMultitaskingCameraAccess = $0 }
        )
    }

    private func addPicker(
        title: String,
        options: [some PickerOption],
        current: @escaping () -> Int,
        apply: @escaping (Int) -> Void
    ) {
        let titleLabel = UILabel()
        titleLabel.text = title.uppercased()
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        let segmented = UISegmentedControl(items: options.map(\.label))
        segmented.selectedSegmentIndex = current()
        segmented.addAction(UIAction { _ in
            apply(segmented.selectedSegmentIndex)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [titleLabel, segmented])
        row.axis = .vertical
        row.spacing = 4
        contentStack.addArrangedSubview(row)
    }

    private func addToggle(
        title: String,
        initial: Bool,
        apply: @escaping (Bool) -> Void
    ) {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        let toggle = UISwitch()
        toggle.isOn = initial
        toggle.addAction(UIAction { _ in apply(toggle.isOn) }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center
        contentStack.addArrangedSubview(row)
    }

    // MARK: - Boot / apply

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        if configuration.includesAudio, PRMPermissions.microphoneStatus() == .notDetermined {
            _ = await PRMPermissions.requestMicrophoneAccess()
        }
        await applyConfigurationAsync()
    }

    private func applyConfiguration() {
        Task { await applyConfigurationAsync() }
    }

    private func applyConfigurationAsync() async {
        await camera.stop()
        do {
            try await camera.configure(configuration)
        } catch {
            statusLabel.text = "Configure failed: \(error.localizedDescription)"
            return
        }

        // Re-wire pipeline if video data output is enabled.
        if configuration.includesVideoDataOutput {
            pipeline.isEnabled = true
            await camera.session.setVideoDataOutputDelegate(pipeline)
            pipeline.onFrame = { [weak self] frame in
                self?.previewView.update(frame.pixelBuffer)
            }
        } else {
            pipeline.isEnabled = false
        }

        await camera.start()
        statusLabel.text = describeApplied()
    }

    private func describeApplied() -> String {
        let device = camera.device
        var lines = ["Applied. Device: \(device?.localizedName ?? "unknown")"]
        if let device {
            lines.append("Lenses: \(device.lenses.count); maxZoom: \(String(format: "%.1f×", device.maxZoomFactor))")
            lines.append("Slow-mo: \(device.supportsSlowMotion); maxFPS: \(Int(device.maxFrameRate))")
        }
        lines.append("Preset: \(configuration.sessionPreset.rawValue)")
        lines.append("Pixel format: \(pixelFormatString(configuration.videoPixelFormat))")
        return lines.joined(separator: "\n")
    }

    private func pixelFormatString(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA: "32BGRA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8 (video range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420YpCbCr8 (full range)"
        default: "0x\(String(format, radix: 16))"
        }
    }
}

// MARK: - Picker options

private protocol PickerOption {
    var label: String { get }
}

private enum SessionPresetOption: CaseIterable, PickerOption {
    case photo, hd720, hd1080, hd4K, high, medium, low

    var preset: AVCaptureSession.Preset {
        switch self {
        case .photo: .photo
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        case .hd4K: .hd4K3840x2160
        case .high: .high
        case .medium: .medium
        case .low: .low
        }
    }

    var label: String {
        switch self {
        case .photo: "photo"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .hd4K: "4K"
        case .high: "high"
        case .medium: "med"
        case .low: "low"
        }
    }
}

private enum PositionOption: CaseIterable, PickerOption {
    case back, front

    var position: AVCaptureDevice.Position {
        switch self {
        case .back: .back
        case .front: .front
        }
    }

    var label: String {
        switch self {
        case .back: "Back"
        case .front: "Front"
        }
    }
}

private enum DeviceTypeOption: CaseIterable, PickerOption {
    case defaultOrder, tripleOnly, wideOnly, dualWideOnly

    var types: [AVCaptureDevice.DeviceType] {
        switch self {
        case .defaultOrder: PRMCameraConfiguration.defaultDeviceTypes
        case .tripleOnly: [.builtInTripleCamera]
        case .wideOnly: [.builtInWideAngleCamera]
        case .dualWideOnly: [.builtInDualWideCamera]
        }
    }

    var label: String {
        switch self {
        case .defaultOrder: "Default"
        case .tripleOnly: "Triple"
        case .wideOnly: "Wide"
        case .dualWideOnly: "DualWide"
        }
    }
}

private enum PixelFormatOption: CaseIterable, PickerOption {
    case bgra32, yuv420Video, yuv420Full

    var value: OSType {
        switch self {
        case .bgra32: kCVPixelFormatType_32BGRA
        case .yuv420Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv420Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    var label: String {
        switch self {
        case .bgra32: "BGRA"
        case .yuv420Video: "YUV-V"
        case .yuv420Full: "YUV-F"
        }
    }
}

private enum QualityOption: CaseIterable, PickerOption {
    case speed, balanced, quality

    var value: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
        case .speed: .speed
        case .balanced: .balanced
        case .quality: .quality
        }
    }

    var label: String {
        switch self {
        case .speed: "Speed"
        case .balanced: "Bal"
        case .quality: "Qual"
        }
    }
}

private enum StabilizationOption: CaseIterable, PickerOption {
    case auto, off, standard, cinematic

    var value: AVCaptureVideoStabilizationMode {
        switch self {
        case .auto: .auto
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        }
    }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .standard: "Std"
        case .cinematic: "Cinem"
        }
    }
}
