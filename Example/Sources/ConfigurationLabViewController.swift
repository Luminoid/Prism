@preconcurrency import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - ConfigurationLabViewController

/// Exposes every knob on `PRMCameraConfiguration` so the user can build a configuration, then
/// "Apply" it to a live preview. Demonstrates `PRMCamera.configure(_:)` re-runs and the
/// session-level toggles that Studio leaves at their defaults.
///
/// Mutual-exclusion rules wire common AVFoundation incompatibilities directly into the UI
/// (instead of letting them silently drop one feature at Apply time):
/// - Movie file output ↔ Live Photo (they can't share a session),
/// - Portrait matte needs depth (matte on turns depth on; depth off turns matte off),
/// - Auto-deferred photo delivery ↔ depth and matte (deferred routes depth through a proxy
///   whose depth map arrives empty on iPhone Pro models),
/// - every photo-output feature needs the photo output (turning one on turns it on; turning
///   the output off turns them all off),
/// - Cinematic Video (iOS 26) ↔ Live Photo / depth / Portrait matte (it brings its own depth
///   pipeline and movie output),
/// - AirPods high-quality recording (iOS 26) needs the audio input.
///
/// The iOS 26 / 27 group also covers deferred start, lens smudge detection, sensor
/// orientation compensation and the metadata output. After Apply the status lists what the
/// camera supports and what actually landed on the session (read back from it, not echoed
/// from the configuration), and a chip over the preview counts detected objects.
///
/// "Capture" takes a still through the applied photo output: the Capture section's codec,
/// depth and the matte requested when they landed on the output. The status then reports
/// the saved container, size and whether depth and matte came back.
@MainActor
final class ConfigurationLabViewController: UIViewController {
    // MARK: - Types

    /// Keys for each toggle in `toggles`, so mutual-exclusion rules can reach their peers.
    private enum ToggleKey: Hashable {
        case audio, videoData, photo, movie
        case responsive, autoDeferred, zeroShutterLag
        case livePhoto, depth, portraitMatte, multitasking
        case metadataOutput, bluetoothHighQuality, cinematic

        /// Features of the photo output, which need it attached.
        static let photoScoped: [Self] = [.livePhoto, .depth, .portraitMatte, .responsive, .zeroShutterLag, .autoDeferred]
    }

    /// What landed on the session, read back from it on the camera actor.
    private struct LandedState: Sendable {
        var outputs: [String] = []
        var livePhoto = false
        var depthDelivery = false
        var matteDelivery = false
        var responsiveCapture = false
        var autoDeferredDelivery = false
        var zeroShutterLag = false
        var multitasking = false
    }

    // MARK: - Properties

    private var configuration = PRMCameraConfiguration()
    /// The codec for Capture: a capture setting, not part of the configuration.
    private var captureCodec: AVVideoCodecType = .hevc
    private let host = CameraPreviewHost(name: "ConfigLab", requestsMicrophone: true)
    private var camera: PRMCamera { host.camera }
    private var photoCapture: PRMPhotoCapture?
    /// What the last Apply produced; Capture only requests depth and matte that landed (a
    /// request the output doesn't deliver raises an exception AVFoundation won't let us catch).
    private var landed = LandedState()
    private var applyTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    /// The configuration's toggles, so mutual-exclusion rules can flip their peers.
    private var toggles: [ToggleKey: UISwitch] = [:]
    private lazy var toaster = ToastPresenter(hostView: view, below: host.previewView.snp.top)

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private lazy var statusLabel: PaddedLabel = {
        let label = PaddedLabel()
        label.text = "Starting the camera…"
        label.textColor = UIColor.white.withAlphaComponent(0.8)
        label.font = ExampleFont.scaled(12, style: .footnote)
        label.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        label.numberOfLines = 0
        return label
    }()

    /// Shown over the preview when `includesVideoDataOutput` is off: without frames the
    /// preview would just freeze on its last one.
    private lazy var previewPlaceholder: UILabel = {
        let label = UILabel()
        label.text = "Preview off: the video data output is disabled"
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.font = ExampleFont.scaled(12, weight: .semibold, style: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = .black
        label.isHidden = true
        return label
    }()

    /// Counts from `PRMCamera.detectedObjectsStream()`, shown while object detection or
    /// Cinematic Video is configured.
    private lazy var detectionLabel: PaddedLabel = {
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        label.font = ExampleFont.monospaced(11, weight: .semibold, style: .caption1, maximum: 16)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.isHidden = true
        return label
    }()

    private lazy var captureButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Capture"
        configuration.baseForegroundColor = .systemYellow
        configuration.baseBackgroundColor = .systemYellow
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.isEnabled = false
        button.accessibilityHint = "Takes a photo with the applied configuration and saves it to Photos"
        button.addAction(UIAction { [weak self] _ in self?.capture() }, for: .touchUpInside)
        return button
    }()

    private lazy var applyButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Apply Configuration"
        configuration.baseBackgroundColor = .systemYellow
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.applyConfiguration() }, for: .touchUpInside)
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.title = "Configuration Lab"
        navigationItem.largeTitleDisplayMode = .never
        host.delegate = self
        host.addLoop { [weak self, camera = host.camera] in
            for await objects in camera.detectedObjectsStream() {
                self?.showDetections(objects)
            }
        }
        setupLayout()
        populateContent()
        // The first boot is an Apply of the default configuration.
        setBusy(applying: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.viewWillAppear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        host.viewDidDisappear(awaiting: captureTask.map { [$0] } ?? [])
    }

    // MARK: - Layout

    private func setupLayout() {
        let previewView = host.previewView
        view.addSubview(previewView)
        // Letterbox the full frame, so the preview shows what Capture saves.
        previewView.contentFit = .fit
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.35)
        }
        view.addSubview(previewPlaceholder)
        previewPlaceholder.snp.makeConstraints { $0.edges.equalTo(previewView) }
        view.addSubview(detectionLabel)
        detectionLabel.snp.makeConstraints {
            $0.leading.equalTo(previewView).offset(12)
            $0.bottom.equalTo(previewView).offset(-12)
        }

        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        view.addSubview(captureButton)
        captureButton.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(16)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
            $0.height.greaterThanOrEqualTo(44)
            $0.width.equalTo(110)
        }
        view.addSubview(applyButton)
        applyButton.snp.makeConstraints {
            $0.leading.equalTo(captureButton.snp.trailing).offset(8)
            $0.trailing.equalToSuperview().offset(-16)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
            $0.height.equalTo(captureButton)
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
        addSectionHeader("Session")
        addPicker(title: "Session preset", options: SessionPresetOption.allCases, value: \.preset, setting: \.sessionPreset)
        addPicker(title: "Camera position", options: PositionOption.allCases, value: \.position, setting: \.cameraPosition)
        addPicker(title: "Device types", options: DeviceTypeOption.allCases, value: \.types, setting: \.deviceTypes)
        addPicker(title: "Video pixel format", options: PixelFormatOption.allCases, value: \.value, setting: \.videoPixelFormat)
        addPicker(title: "Photo quality ceiling", options: QualityOption.allCases, value: \.value, setting: \.maxPhotoQualityPrioritization)
        addPicker(title: "Preferred stabilization", options: StabilizationOption.available, value: \.mode, setting: \.preferredVideoStabilizationMode)

        addSectionHeader("Inputs and outputs")
        addToggle(.audio, title: "Include audio input", setting: \.includesAudio)
        addToggle(.videoData, title: "Video data output (filters)", setting: \.includesVideoDataOutput)
        addToggle(.photo, title: "Photo output", setting: \.includesPhotoOutput)
        addToggle(.movie, title: "Movie file output", setting: \.includesMovieFileOutput)
        addToggle(.multitasking, title: "Multitasking camera access (iPad)", setting: \.enableMultitaskingCameraAccess)

        addSectionHeader("Photo output")
        addToggle(.responsive, title: "Responsive capture (iOS 17+)", setting: \.enableResponsiveCapture)
        addToggle(.autoDeferred, title: "Auto-deferred photo delivery", setting: \.enableAutoDeferredPhotoDelivery)
        addToggle(.zeroShutterLag, title: "Zero shutter lag", setting: \.enableZeroShutterLag)
        addToggle(.livePhoto, title: "Live Photo capture", setting: \.enableLivePhoto)
        addToggle(.depth, title: "Depth-data delivery", setting: \.enableDepthDataDelivery)
        addToggle(.portraitMatte, title: "Portrait-effects matte", setting: \.enablePortraitEffectsMatteDelivery)

        addSectionHeader("iOS 26 / 27")
        addPicker(title: "Deferred start (iOS 26)", options: DeferredStartOption.allCases, value: \.value, setting: \.deferredStart)
        addPicker(title: "Lens smudge detection (iOS 26)", options: SmudgeDetectionOption.allCases, value: \.interval, setting: \.lensSmudgeDetectionInterval)
        addPicker(
            title: "Sensor orientation compensation (iOS 26)",
            options: OrientationCompensationOption.allCases,
            value: \.value,
            setting: \.enableCameraSensorOrientationCompensation
        )
        addPicker(title: "Detect objects (metadata output)", options: DetectionOption.allCases, value: \.types, setting: \.metadataObjectTypes)
        addToggle(.metadataOutput, title: "Attach metadata output at configure", setting: \.includesMetadataOutput)
        addToggle(.bluetoothHighQuality, title: "AirPods high-quality mic (iOS 26)", setting: \.enableBluetoothHighQualityRecording)
        addToggle(.cinematic, title: "Cinematic Video (iOS 26)", setting: \.enableCinematicVideo)

        addSectionHeader("Capture")
        let codecs = CodecOption.allCases
        addPicker(title: "Photo codec", labels: codecs.map(\.label), selected: codecs.firstIndex { $0.value == captureCodec } ?? 0) { [weak self] index in
            self?.captureCodec = codecs[index].value
        }
    }

    private func addSectionHeader(_ title: String) {
        if let previous = contentStack.arrangedSubviews.last {
            contentStack.setCustomSpacing(20, after: previous)
        }
        contentStack.addArrangedSubview(SectionHeaderLabel(title))
    }

    /// A picker bound to one configuration property: the segment whose option value equals the
    /// property is selected, and picking one writes its value back.
    private func addPicker<Option: PickerOption, Value: Equatable>(
        title: String,
        options: [Option],
        value: KeyPath<Option, Value>,
        setting: WritableKeyPath<PRMCameraConfiguration, Value>
    ) {
        let current = configuration[keyPath: setting]
        let selected = options.firstIndex { $0[keyPath: value] == current } ?? 0
        addPicker(title: title, labels: options.map(\.label), selected: selected) { [weak self] index in
            self?.configuration[keyPath: setting] = options[index][keyPath: value]
        }
    }

    private func addPicker(title: String, labels: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        let titleLabel = makeFieldLabel(title)
        let segmented = UISegmentedControl(items: labels)
        segmented.selectedSegmentIndex = selected
        segmented.accessibilityLabel = title
        segmented.addAction(UIAction { action in
            guard let segmented = action.sender as? UISegmentedControl, labels.indices.contains(segmented.selectedSegmentIndex) else { return }
            onSelect(segmented.selectedSegmentIndex)
        }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [titleLabel, segmented])
        row.axis = .vertical
        row.spacing = 6
        contentStack.addArrangedSubview(row)
    }

    private func addToggle(_ key: ToggleKey, title: String, setting: WritableKeyPath<PRMCameraConfiguration, Bool>) {
        let label = makeFieldLabel(title)
        let toggle = UISwitch()
        toggle.isOn = configuration[keyPath: setting]
        toggle.accessibilityLabel = title
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            configuration[keyPath: setting] = toggle.isOn
            enforceMutualExclusion(changed: key, isOn: toggle.isOn)
        }, for: .valueChanged)
        toggles[key] = toggle
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        contentStack.addArrangedSubview(row)
    }

    /// A field's title; the control next to it carries the same text for VoiceOver.
    private func makeFieldLabel(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = ExampleFont.scaled(13, style: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        return label
    }

    /// Turns AVFoundation-incompatible peers off (and required ones on) so the user sees the
    /// conflict now instead of a silent drop at Apply. The pairs are listed in the type's
    /// documentation.
    private func enforceMutualExclusion(changed: ToggleKey, isOn: Bool) {
        guard isOn else {
            switch changed {
            case .photo:
                for key in ToggleKey.photoScoped {
                    setToggle(key, to: false)
                }
            case .depth:
                setToggle(.portraitMatte, to: false)
            case .audio:
                setToggle(.bluetoothHighQuality, to: false)
            default:
                break
            }
            return
        }
        if ToggleKey.photoScoped.contains(changed) {
            setToggle(.photo, to: true)
        }
        switch changed {
        case .movie:
            setToggle(.livePhoto, to: false)
        case .livePhoto:
            setToggle(.movie, to: false)
            setToggle(.cinematic, to: false)
        case .depth:
            setToggle(.autoDeferred, to: false)
            setToggle(.cinematic, to: false)
        case .portraitMatte:
            setToggle(.depth, to: true)
            setToggle(.autoDeferred, to: false)
            setToggle(.cinematic, to: false)
        case .autoDeferred:
            setToggle(.depth, to: false)
            setToggle(.portraitMatte, to: false)
        case .cinematic:
            setToggle(.livePhoto, to: false)
            setToggle(.depth, to: false)
            setToggle(.portraitMatte, to: false)
        case .bluetoothHighQuality:
            setToggle(.audio, to: true)
        default:
            break
        }
    }

    /// Flips a peer and runs its action, so its own rules apply too.
    private func setToggle(_ key: ToggleKey, to isOn: Bool) {
        guard let toggle = toggles[key], toggle.isOn != isOn else { return }
        toggle.setOn(isOn, animated: true)
        toggle.sendActions(for: .valueChanged)
    }

    // MARK: - Apply

    private func applyConfiguration() {
        guard applyTask == nil, captureTask == nil else { return }
        setBusy(applying: true)
        applyTask = Task { [weak self, host] in
            await host.reconfigure()
            self?.applyTask = nil
            self?.setBusy(applying: false)
        }
    }

    /// Apply and Capture are unavailable while either runs; Apply says what it's doing.
    private func setBusy(applying: Bool) {
        let busy = applying || captureTask != nil
        applyButton.isEnabled = !busy
        applyButton.configuration?.title = applying ? "Applying…" : "Apply Configuration"
        applyButton.configuration?.showsActivityIndicator = applying
        captureButton.isEnabled = !busy && photoCapture != nil && landed.outputs.contains("photo")
    }

    // MARK: - Detection feed

    private func showDetections(_ objects: [PRMDetectedObject]) {
        guard !detectionLabel.isHidden else { return }
        let text = Self.detectionSummary(objects)
        if detectionLabel.text != text {
            detectionLabel.text = text
        }
    }

    private static func detectionSummary(_ objects: [PRMDetectedObject]) -> String {
        guard !objects.isEmpty else { return "No detections" }
        var counts: [String: Int] = [:]
        for object in objects {
            counts[name(of: object.kind), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
    }

    private static func name(of kind: PRMDetectedObject.Kind) -> String {
        switch kind {
        case .focusTracked: "tracked"
        case .face: "face"
        case .humanBody: "body"
        case .humanFullBody: "full body"
        case .catHead: "cat head"
        case .catBody: "cat"
        case .dogHead: "dog head"
        case .dogBody: "dog"
        case .salientObject: "salient"
        case let .other(raw): raw
        }
    }

    // MARK: - Capture

    /// A still through the applied photo output, with the lab's codec and the depth and matte
    /// that landed, rotated to how the phone is held.
    private func capture() {
        guard let photoCapture, captureTask == nil, applyTask == nil else { return }
        var settings = PRMPhotoSettings()
            .flashMode(.off)
            .qualityPrioritization(configuration.maxPhotoQualityPrioritization)
            .codec(captureCodec)
            .rotationAngle(host.captureRotationAngle)
        let requestsDepth = configuration.enableDepthDataDelivery && landed.depthDelivery
        let requestsMatte = requestsDepth && configuration.enablePortraitEffectsMatteDelivery && landed.matteDelivery
        if requestsDepth {
            settings = settings.depthDataDelivery(true).embedsDepthDataInPhoto(true)
        }
        if requestsMatte {
            // The matte needs depth delivery on, and embedding it needs embedded depth.
            settings = settings.portraitEffectsMatte(true).embedsPortraitEffectsMatteInPhoto(true)
        }
        statusLabel.text = "Capturing…"
        captureTask = Task { [weak self, photoCapture] in
            do {
                let photo = try await photoCapture.capturePhoto(settings: settings)
                try await PhotoLibrarySaver.save(.photo(photo.data))
                var parts = [
                    "Saved \(PhotoLibrarySaver.containerLabel(for: photo.data))",
                    "\(photo.data.count / 1024) KB",
                ]
                if requestsDepth { parts.append(photo.underlyingPhoto.depthData == nil ? "no depth" : "with depth") }
                if requestsMatte { parts.append(photo.underlyingPhoto.portraitEffectsMatte == nil ? "no matte" : "with matte") }
                self?.statusLabel.text = parts.joined(separator: " · ")
            } catch {
                self?.statusLabel.text = "Capture failed"
                self?.toaster.report(error, context: "Capture")
            }
            self?.captureTask = nil
            self?.setBusy(applying: false)
        }
        setBusy(applying: false)
    }

    // MARK: - Summary

    private func describeApplied() async -> String {
        landed = await Self.readLandedState(camera.session)
        let device = camera.device
        var lines = ["Applied. Device: \(device?.localizedName ?? "unknown")"]
        if let device {
            lines.append("Lenses: \(Self.lensSummary(device.lenses)); max zoom \(String(format: "%.1f×", device.maxZoomFactor))")
            lines.append("Slow-mo: \(device.supportsSlowMotion ? "yes" : "no"); max \(Int(device.maxFrameRate)) fps")
            let supported = CameraCapability.allCases.filter { $0.isSupported(by: device) }.map { $0.summary(for: device) }
            lines.append("iOS 26/27 support: " + (supported.isEmpty ? "none on this camera and OS" : supported.joined(separator: ", ")))
        }
        lines.append("Preset: \(configuration.sessionPreset.rawValue); pixel format \(Self.pixelFormatName(configuration.videoPixelFormat))")
        // What the session has, not what was asked: features drop out when the camera can't
        // do them (Live Photo on some front cameras, depth on a single camera, multitasking on
        // iPhone).
        lines.append("Outputs: " + (landed.outputs.isEmpty ? "none" : landed.outputs.joined(separator: ", ")))
        lines.append("Photo features: " + photoFeaturesSummary())
        lines.append("iOS 26/27 landed: " + modernLandedSummary())
        return lines.joined(separator: "\n")
    }

    /// The photo-output features that are on, then the requested ones that didn't land.
    private func photoFeaturesSummary() -> String {
        let features: [(name: String, requested: Bool, landed: Bool)] = [
            ("live", configuration.enableLivePhoto, landed.livePhoto),
            ("depth", configuration.enableDepthDataDelivery, landed.depthDelivery),
            ("matte", configuration.enablePortraitEffectsMatteDelivery, landed.matteDelivery),
            ("responsive", configuration.enableResponsiveCapture, landed.responsiveCapture),
            ("deferred", configuration.enableAutoDeferredPhotoDelivery, landed.autoDeferredDelivery),
            ("ZSL", configuration.enableZeroShutterLag, landed.zeroShutterLag),
            ("multitask", configuration.enableMultitaskingCameraAccess, landed.multitasking),
        ]
        let on = features.filter(\.landed).map(\.name)
        let dropped = features.filter { $0.requested && !$0.landed }.map(\.name)
        var text = on.isEmpty ? "none" : on.joined(separator: ", ")
        if !dropped.isEmpty {
            text += " (requested but off: \(dropped.joined(separator: ", ")))"
        }
        return text
    }

    /// What the iOS 26 / 27 settings turned into once the session started.
    private func modernLandedSummary() -> String {
        let state = camera.state
        var parts: [String] = []
        if let option = DeferredStartOption.allCases.first(where: { $0.value == configuration.deferredStart }) {
            parts.append("deferred start \(option.label.lowercased()) (requested)")
        }
        if configuration.lensSmudgeDetectionInterval != nil {
            parts.append("smudge \(state.lensSmudgeStatus)")
        }
        if configuration.enableCinematicVideo {
            parts.append(state.isCinematicVideoCaptureEnabled ? "Cinematic Video on" : "Cinematic Video unavailable")
        }
        if configuration.enableBluetoothHighQualityRecording, configuration.includesAudio {
            parts.append("AirPods HQ mic (requested)")
        }
        if let compensation = configuration.enableCameraSensorOrientationCompensation {
            parts.append("orientation compensation \(compensation ? "on" : "off") (requested)")
        }
        return parts.isEmpty ? "nothing requested" : parts.joined(separator: ", ")
    }

    /// Focal lengths as Studio's lens chips label them. iOS 26 reports Apple's nominal
    /// values; older systems derive them from each lens's field of view.
    private static func lensSummary(_ lenses: [PRMLens]) -> String {
        guard !lenses.isEmpty else { return "none" }
        let focalLengths = lenses.map { "\(Int($0.snapping().focalLength35mm.rounded()))" }.joined(separator: "/")
        let source = lenses.allSatisfy { $0.focalLengthSource == .nominal } ? "nominal" : "from FOV"
        return "\(focalLengths) mm (\(source))"
    }

    private static func pixelFormatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA: "32BGRA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8 (video range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420YpCbCr8 (full range)"
        default: "0x\(String(format, radix: 16))"
        }
    }

    /// Reads the session's outputs and photo-output flags in one turn on the camera actor.
    @PRMCameraActor
    private static func readLandedState(_ session: PRMCameraSession) -> LandedState {
        var state = LandedState()
        if session.audioDeviceInput != nil { state.outputs.append("audio") }
        if session.videoDataOutput != nil { state.outputs.append("video-data") }
        if session.photoOutput != nil { state.outputs.append("photo") }
        if session.movieFileOutput != nil { state.outputs.append("movie") }
        if let metadata = session.metadataOutput {
            state.outputs.append("metadata (\(metadata.metadataObjectTypes.count) types)")
        }
        if let photo = session.photoOutput {
            state.livePhoto = photo.isLivePhotoCaptureEnabled
            state.depthDelivery = photo.isDepthDataDeliveryEnabled
            state.matteDelivery = photo.isPortraitEffectsMatteDeliveryEnabled
            state.responsiveCapture = photo.isResponsiveCaptureEnabled
            state.autoDeferredDelivery = photo.isAutoDeferredPhotoDeliveryEnabled
            state.zeroShutterLag = photo.isZeroShutterLagEnabled
        }
        state.multitasking = session.session.isMultitaskingCameraAccessEnabled
        return state
    }
}

// MARK: - CameraPreviewHostDelegate

extension ConfigurationLabViewController: CameraPreviewHostDelegate {
    func cameraHostConfigure(_ host: CameraPreviewHost) async throws {
        try await host.camera.configure(configuration)
    }

    func cameraHostDidConfigure(_ host: CameraPreviewHost) async {
        // Without the video data output the preview gets no frames; say so instead of
        // showing a frozen frame.
        previewPlaceholder.isHidden = configuration.includesVideoDataOutput
        // The session-based wrapper resolves whatever photo output this configuration
        // attached, at each capture.
        photoCapture = photoCapture ?? PRMPhotoCapture(session: host.camera.session)
        let detects = !configuration.metadataObjectTypes.isEmpty || configuration.enableCinematicVideo
        detectionLabel.isHidden = !detects
        detectionLabel.text = Self.detectionSummary([])
    }

    func cameraHostDidStart(_: CameraPreviewHost) async {
        // Smudge status, Cinematic Video and the metadata output settle during start.
        await camera.refreshState()
        statusLabel.text = await describeApplied()
        setBusy(applying: false)
    }

    func cameraHost(_: CameraPreviewHost, didFailToConfigure error: any Error) {
        landed = LandedState()
        statusLabel.text = "Configure failed: \(error.localizedDescription)"
        previewPlaceholder.text = "Configure failed; see the status"
        previewPlaceholder.isHidden = false
        setBusy(applying: false)
        toaster.report(error, context: "Configure")
    }

    func cameraHost(_: CameraPreviewHost, didReceive error: PRMSessionError) {
        toaster.report(error, context: "Camera")
    }
}

// MARK: - Picker options

private protocol PickerOption {
    var label: String { get }
}

extension StabilizationOption: PickerOption {}

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

private enum DeferredStartOption: CaseIterable, PickerOption {
    case system, off, photoAndMovie

    var value: PRMDeferredStart {
        switch self {
        case .system: .systemDefault
        case .off: .disabled
        case .photoAndMovie: .photoAndMovie
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .off: "Off"
        case .photoAndMovie: "Photo+Movie"
        }
    }
}

private enum SmudgeDetectionOption: CaseIterable, PickerOption {
    case off, once, continuous, every30Seconds

    /// `nil` = off, `.invalid` = once per session start, `.zero` = continuously.
    var interval: CMTime? {
        switch self {
        case .off: nil
        case .once: .invalid
        case .continuous: .zero
        case .every30Seconds: CMTime(value: 30, timescale: 1)
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .once: "Once"
        case .continuous: "Always"
        case .every30Seconds: "30 s"
        }
    }
}

private enum OrientationCompensationOption: CaseIterable, PickerOption {
    case system, on, off

    var value: Bool? {
        switch self {
        case .system: nil
        case .on: true
        case .off: false
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .on: "On"
        case .off: "Off"
        }
    }
}

private enum DetectionOption: CaseIterable, PickerOption {
    case off, faces, people, pets

    var types: [AVMetadataObject.ObjectType] {
        switch self {
        case .off: []
        case .faces: [.face]
        case .people: [.face, .humanBody, .humanFullBody]
        case .pets: Self.petTypes
        }
    }

    /// Cat and dog heads are iOS 26+; bodies are older.
    private static var petTypes: [AVMetadataObject.ObjectType] {
        if #available(iOS 26.0, *) {
            return [.catHead, .catBody, .dogHead, .dogBody]
        }
        return [.catBody, .dogBody]
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .faces: "Faces"
        case .people: "People"
        case .pets: "Pets"
        }
    }
}

private enum CodecOption: CaseIterable, PickerOption {
    case heic, jpeg

    var value: AVVideoCodecType {
        switch self {
        case .heic: .hevc
        case .jpeg: .jpeg
        }
    }

    var label: String {
        switch self {
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        }
    }
}
