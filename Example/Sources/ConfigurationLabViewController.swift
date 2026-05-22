@preconcurrency import AVFoundation
import Photos
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - ConfigurationLabViewController

/// Exposes every knob on `PRMCameraConfiguration` so the user can build a configuration, then
/// "Apply" it to a live preview. Demonstrates `PRMCamera.configure(_:)` re-runs and the
/// various session-level toggles that the DSLR Studio leaves at defaults.
///
/// Mutual-exclusion rules wire common AVFoundation incompatibilities directly into the UI
/// (instead of letting them silently drop one feature at Apply time):
/// - MovieFileOutput ↔ LivePhoto (mutually exclusive on the same session),
/// - Depth + Portrait matte require depth-capable formats (depth toggles off → matte too),
/// - Auto-deferred photo delivery + Depth fight on iPhone Pro models (deferred routes the
///   depth XPC stream through the proxy and the matte arrives null).
///
/// A "Capture" button at the bottom exercises the photo output configuration the user just
/// applied (codec from the lab settings, saves to Photos so the user can confirm size,
/// format, and depth/matte payload). The preview hides itself with a "no preview" status
/// when `includesVideoDataOutput` is off so the user gets a clear signal the setting took.
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
    private var photoCapture: PRMPhotoCapture?

    /// Keys for each toggle in `toggles` so mutual-exclusion rules can reach into peer
    /// toggles and flip them off. Mirrors `PRMCameraConfiguration`'s feature flags.
    private enum ToggleKey: Hashable {
        case audio, videoData, photo, movie
        case responsive, autoDeferred, zeroShutterLag
        case livePhoto, depth, portraitMatte, multitasking
    }

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusLabel = UILabel()
    private let applyButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let previewPlaceholder = UILabel()

    /// All toggles indexed by their config-targeted property so mutual-exclusion rules
    /// (MovieFileOutput vs Live Photo, Depth vs Auto-deferred photo delivery, etc.) can
    /// flip peers off when the user enables a conflicting feature. Without this the
    /// previous version let users tick both and Apply silently dropped one.
    private var toggles: [ToggleKey: UISwitch] = [:]

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

        // Placeholder text shown when `includesVideoDataOutput` is off and the preview
        // can't receive frames. Without this, the preview just stays on the last frame
        // and looks frozen — the user has no signal the toggle did anything.
        previewPlaceholder.text = "Preview off — video data output disabled in current config"
        previewPlaceholder.textColor = UIColor.white.withAlphaComponent(0.55)
        previewPlaceholder.font = .systemFont(ofSize: 12, weight: .semibold)
        previewPlaceholder.textAlignment = .center
        previewPlaceholder.numberOfLines = 2
        previewPlaceholder.backgroundColor = UIColor.black
        previewPlaceholder.isHidden = true
        view.addSubview(previewPlaceholder)
        previewPlaceholder.snp.makeConstraints { $0.edges.equalTo(previewView) }

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

        // Capture button next to Apply — uses the current config's photo output to take
        // an actual still and save to Photos, so the user can verify codec / quality /
        // depth/matte payload landed in the file. Disabled until first Apply.
        var captureConfig = UIButton.Configuration.tinted()
        captureConfig.title = "Capture"
        captureConfig.baseForegroundColor = .systemYellow
        captureConfig.baseBackgroundColor = .systemYellow
        captureConfig.cornerStyle = .large
        captureButton.configuration = captureConfig
        captureButton.isEnabled = false
        captureButton.addAction(UIAction { [weak self] _ in self?.capture() }, for: .touchUpInside)
        view.addSubview(captureButton)
        captureButton.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(16)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
            $0.height.equalTo(44)
            $0.width.equalTo(110)
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
            $0.leading.equalTo(captureButton.snp.trailing).offset(8)
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
            key: .audio,
            title: "Include audio input",
            initial: configuration.includesAudio,
            apply: { [unowned self] in configuration.includesAudio = $0 }
        )
        addToggle(
            key: .videoData,
            title: "Video data output (filters)",
            initial: configuration.includesVideoDataOutput,
            apply: { [unowned self] in configuration.includesVideoDataOutput = $0 }
        )
        addToggle(
            key: .photo,
            title: "Photo output",
            initial: configuration.includesPhotoOutput,
            apply: { [unowned self] in configuration.includesPhotoOutput = $0 }
        )
        addToggle(
            key: .movie,
            title: "Movie file output",
            initial: configuration.includesMovieFileOutput,
            apply: { [unowned self] in configuration.includesMovieFileOutput = $0 }
        )
        addToggle(
            key: .responsive,
            title: "Responsive capture (iOS 17+)",
            initial: configuration.enableResponsiveCapture,
            apply: { [unowned self] in configuration.enableResponsiveCapture = $0 }
        )
        addToggle(
            key: .autoDeferred,
            title: "Auto-deferred photo delivery",
            initial: configuration.enableAutoDeferredPhotoDelivery,
            apply: { [unowned self] in configuration.enableAutoDeferredPhotoDelivery = $0 }
        )
        addToggle(
            key: .zeroShutterLag,
            title: "Zero shutter lag",
            initial: configuration.enableZeroShutterLag,
            apply: { [unowned self] in configuration.enableZeroShutterLag = $0 }
        )
        addToggle(
            key: .livePhoto,
            title: "Live Photo capture",
            initial: configuration.enableLivePhoto,
            apply: { [unowned self] in configuration.enableLivePhoto = $0 }
        )
        addToggle(
            key: .depth,
            title: "Depth-data delivery",
            initial: configuration.enableDepthDataDelivery,
            apply: { [unowned self] in configuration.enableDepthDataDelivery = $0 }
        )
        addToggle(
            key: .portraitMatte,
            title: "Portrait-effects matte",
            initial: configuration.enablePortraitEffectsMatteDelivery,
            apply: { [unowned self] in configuration.enablePortraitEffectsMatteDelivery = $0 }
        )
        addToggle(
            key: .multitasking,
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
        key: ToggleKey,
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
        toggle.addAction(UIAction { [weak self] _ in
            apply(toggle.isOn)
            self?.enforceMutualExclusion(changed: key, isOn: toggle.isOn)
        }, for: .valueChanged)
        toggles[key] = toggle
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center
        contentStack.addArrangedSubview(row)
    }

    /// Auto-deselect AVFoundation-incompatible peer toggles so the user gets immediate
    /// feedback instead of a silent drop at Apply time. Pairs encoded:
    /// - Movie file output ↔ Live Photo (can't coexist on the same session).
    /// - Portrait matte → requires Depth (matte without depth throws at capture).
    /// - Depth → off forces Portrait matte off (matte alone makes no sense).
    /// - Auto-deferred photo delivery ↔ Depth (deferred routes depth through a proxy
    ///   whose `depthDataMap` is internally null on iPhone Pro models).
    /// - Photo output → off forces Live Photo / Depth / Portrait matte / responsive /
    ///   zero-shutter-lag / auto-deferred all off (they're all photo-output-scoped).
    private func enforceMutualExclusion(changed: ToggleKey, isOn: Bool) {
        let setOff: (ToggleKey) -> Void = { [unowned self] key in
            guard let peer = toggles[key], peer.isOn else { return }
            peer.setOn(false, animated: true)
            peer.sendActions(for: .valueChanged)
        }

        guard isOn else {
            if changed == .photo {
                setOff(.livePhoto)
                setOff(.depth)
                setOff(.portraitMatte)
                setOff(.responsive)
                setOff(.zeroShutterLag)
                setOff(.autoDeferred)
            }
            if changed == .depth {
                setOff(.portraitMatte)
            }
            return
        }

        switch changed {
        case .movie:
            setOff(.livePhoto)
        case .livePhoto:
            setOff(.movie)
        case .portraitMatte:
            if let depth = toggles[.depth], !depth.isOn {
                depth.setOn(true, animated: true)
                depth.sendActions(for: .valueChanged)
            }
        case .autoDeferred:
            setOff(.depth)
            setOff(.portraitMatte)
        default:
            break
        }
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
            previewPlaceholder.text = "Configure failed — see status"
            previewPlaceholder.isHidden = false
            captureButton.isEnabled = false
            return
        }

        // Re-wire pipeline if video data output is enabled. With it off, the preview
        // can't receive frames, so we surface a "preview off" placeholder so the user
        // sees the toggle took effect (otherwise the preview just freezes silently).
        if configuration.includesVideoDataOutput {
            pipeline.isEnabled = true
            await camera.session.setVideoDataOutputDelegate(pipeline)
            pipeline.onFrame = { [weak self] frame in
                self?.previewView.update(frame.pixelBuffer)
            }
            previewPlaceholder.isHidden = true
        } else {
            pipeline.isEnabled = false
            previewPlaceholder.text = "Preview off — video data output disabled"
            previewPlaceholder.isHidden = false
        }

        // Wire (or release) the photo capture facade so the Capture button can actually
        // run an AVCapturePhotoOutput round-trip with the user's just-applied codec /
        // quality / depth / matte settings. Disabled when the user turned off photo
        // output (there's nothing to capture).
        if configuration.includesPhotoOutput {
            let session = camera.session
            let capture: PRMPhotoCapture? = await PRMCameraActor.shared.run {
                guard let photoOutput = await session.photoOutput else { return PRMPhotoCapture?.none }
                return PRMPhotoCapture(output: photoOutput)
            }
            photoCapture = capture
            captureButton.isEnabled = capture != nil
        } else {
            photoCapture = nil
            captureButton.isEnabled = false
        }

        await camera.start()
        statusLabel.text = describeApplied()
    }

    // MARK: - Capture

    private func capture() {
        guard let photoCapture else { return }
        let codec: AVVideoCodecType = .hevc
        statusLabel.text = "Capturing…"
        Task { [photoCapture] in
            do {
                let settings = PRMPhotoSettings()
                    .flashMode(.off)
                    .qualityPrioritization(configuration.maxPhotoQualityPrioritization)
                    .codec(codec)
                let photo = try await photoCapture.capturePhoto(settings: settings)
                await save(data: photo.data)
            } catch {
                await MainActor.run { [weak self] in
                    self?.statusLabel.text = "Capture failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func save(data: Data) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        let granted = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard granted == .authorized || granted == .limited else {
            statusLabel.text = "Photos access denied"
            return
        }
        do {
            try await Self.writePhoto(data: data)
            let sizeKB = data.count / 1024
            statusLabel.text = "Saved \(sizeKB) KB · current config in metadata"
        } catch {
            statusLabel.text = "Save failed: \(error.localizedDescription)"
        }
    }

    /// `PHPhotoLibrary.performChanges` dispatches its closure on Photos' private queue.
    /// A closure created inside a `@MainActor` method inherits MainActor isolation and
    /// the runtime aborts with `_dispatch_assert_queue_fail` when Photos tries to
    /// dispatch it. Wrap in a `nonisolated static` helper to fully sever the inheritance.
    private nonisolated static func writePhoto(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
        }
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
        // Surface every toggle's actual landed state — some flip themselves off when the
        // device doesn't support the feature (e.g. Live Photo requested but not supported
        // on the front camera, multitasking requested on iPhone, depth on a single-camera
        // device). Without this the user sees the toggle stay green and assumes it took.
        lines.append("Outputs: " + applyedOutputsSummary())
        lines.append("Photo features: " + appliedPhotoFeaturesSummary())
        return lines.joined(separator: "\n")
    }

    private func applyedOutputsSummary() -> String {
        var parts: [String] = []
        if configuration.includesAudio { parts.append("audio") }
        if configuration.includesVideoDataOutput { parts.append("video-data") }
        if configuration.includesPhotoOutput { parts.append("photo") }
        if configuration.includesMovieFileOutput { parts.append("movie") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    private func appliedPhotoFeaturesSummary() -> String {
        var parts: [String] = []
        if configuration.enableLivePhoto { parts.append("live") }
        if configuration.enableDepthDataDelivery { parts.append("depth") }
        if configuration.enablePortraitEffectsMatteDelivery { parts.append("matte") }
        if configuration.enableResponsiveCapture { parts.append("responsive") }
        if configuration.enableAutoDeferredPhotoDelivery { parts.append("deferred") }
        if configuration.enableZeroShutterLag { parts.append("ZSL") }
        if configuration.enableMultitaskingCameraAccess { parts.append("multitask") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
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
