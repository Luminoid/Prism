@preconcurrency import AVFoundation
import CoreMotion
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - StudioViewController

/// A DSLR-style camera: live preview, focal-length lens picker, telemetry strip, photo /
/// Live / Portrait / Burst / video / slow-motion / Night modes, tap-to-focus, pinch-to-zoom,
/// drag-to-bias exposure, hardware capture controls and a settings drawer.
///
/// Exercises the full PrismCore + PrismUI surface in one screen, so it spans several files:
/// captures in `StudioViewController+Capture.swift`, device hops and mode setup in
/// `StudioViewController+DeviceHops.swift`, the drawer in ``StudioDrawerControls`` and
/// ``ModernCaptureControls``, and the views in `StudioComponents.swift`.
@MainActor
final class StudioViewController: UIViewController {
    // MARK: - Types

    enum Mode: Equatable {
        case photo, live, portrait, video, slowMo, night

        var label: String {
            switch self {
            case .photo: "PHOTO"
            case .live: "LIVE"
            case .portrait: "PORTRAIT"
            case .video: "VIDEO"
            case .slowMo: "SLO-MO"
            case .night: "NIGHT"
            }
        }

        var isVideo: Bool {
            self == .video || self == .slowMo
        }
    }

    enum FlashSetting {
        case auto, on, off

        var next: Self {
            switch self {
            case .auto: .on
            case .on: .off
            case .off: .auto
            }
        }

        var symbol: String {
            switch self {
            case .auto: "bolt.badge.a.fill"
            case .on: "bolt.fill"
            case .off: "bolt.slash.fill"
            }
        }

        var name: String {
            switch self {
            case .auto: "Auto"
            case .on: "On"
            case .off: "Off"
            }
        }

        var avMode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        }
    }

    enum TimerSetting: Int {
        case off = 0, three = 3, ten = 10

        var next: Self {
            switch self {
            case .off: .three
            case .three: .ten
            case .ten: .off
            }
        }

        var symbol: String {
            switch self {
            case .off: "timer"
            case .three: "3.circle.fill"
            case .ten: "10.circle.fill"
            }
        }
    }

    /// Night capture duration. `.auto` picks from the current ISO and shutter, like the
    /// system Camera; the fixed values override that pick.
    enum NightDuration: Equatable {
        case auto, oneSecond, threeSeconds, fiveSeconds

        var label: String {
            switch self {
            case .auto: "AUTO"
            case .oneSecond: "1s"
            case .threeSeconds: "3s"
            case .fiveSeconds: "5s"
            }
        }

        /// The capture time `PRMNightModeCapture` gathers light for.
        var requested: PRMNightModeOptions.Duration {
            switch self {
            case .auto: .automatic
            case .oneSecond: .seconds(1)
            case .threeSeconds: .seconds(3)
            case .fiveSeconds: .seconds(5)
            }
        }
    }

    /// VIDEO's frame rates: 24 for a film cadence, 30 like the system Camera. 60 fps is left
    /// out on purpose: the `.photo` preset's 4:3 formats top out at 30 fps, so 60 would switch
    /// to a narrower 16:9 video format and visibly resize the preview. SLO-MO covers 120 / 240.
    enum VideoFPS: Equatable {
        case fps24, fps30

        var value: Float64 {
            switch self {
            case .fps24: 24
            case .fps30: 30
            }
        }
    }

    /// Virtual multi-camera devices, which reject manual exposure, white balance and focus.
    static let virtualDeviceTypes: Set<AVCaptureDevice.DeviceType> = [
        .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera,
    ]

    // MARK: - Properties

    /// Camera, pipeline and preview, with the boot and appear / disappear lifecycle. The 2 Hz
    /// state poll keeps the telemetry following auto exposure, which drifts without a setter.
    let host = CameraPreviewHost(name: "Studio", requestsMicrophone: true, statePollInterval: .milliseconds(500))
    var camera: PRMCamera { host.camera }
    var pipeline: PRMFilterPipeline { host.pipeline }
    var previewView: PRMPreviewView { host.previewView }

    /// Session-based capture wrappers: they resolve the session's live outputs at every
    /// capture, so device hops, Live Photo recovery and slow-motion format swaps never leave
    /// them pointing at a replaced output.
    var photoCapture: PRMPhotoCapture?
    var nightCapture: PRMNightModeCapture?
    /// `nil` while the movie output is detached (every mode but VIDEO and SLO-MO).
    var videoRecorder: PRMVideoRecorder?

    var mode: Mode = .photo {
        didSet {
            ExampleLog.session.notice("Studio mode \(oldValue.label, privacy: .public) → \(self.mode.label, privacy: .public)")
            scheduleModeChange()
        }
    }

    var flashSetting: FlashSetting = .auto
    var timerSetting: TimerSetting = .off
    var burstEnabled = false
    var nightDuration: NightDuration = .auto
    var videoFPS: VideoFPS = .fps30
    var aspectIndex = 0
    let aspectCycle: [PRMAspectRatioMaskView.AspectRatio] = [.unconstrained, .ratio4x3, .ratio16x9, .ratio1x1]
    var gridIndex = 0
    let gridCycle: [PRMGridView.GridType?] = [nil, .ruleOfThirds]

    /// Mode changes and camera flips, one at a time: each waits for the one before, and
    /// ``sessionGeneration`` tells a running one that a newer one superseded it.
    var sessionTask: Task<Void, Never>?
    var sessionGeneration = 0
    /// The mode whose session setup last completed; `nil` forces a full setup (boot, flip).
    var appliedMode: Mode?
    /// Set while slow motion runs on the wide camera with the photo output detached.
    var slowMoSetupActive = false
    /// The device slow motion hopped away from, restored on exit.
    var preSlowMoDeviceType: AVCaptureDevice.DeviceType?
    /// The virtual device Studio left for manual controls or NIGHT, restored once exposure and
    /// white balance are both automatic again (and NIGHT is left).
    var preManualDeviceType: AVCaptureDevice.DeviceType?
    /// The hop to the wide camera for manual controls. Slider ticks that arrive during the hop
    /// wait for it instead of starting another.
    var manualHopTask: Task<Void, Never>?
    /// One motion manager for the level indicator and the stability reading (Apple
    /// recommends one per app).
    let motionManager = CMMotionManager()
    /// Whether the phone is still enough for Night's longer frames.
    lazy var stabilityMeter = StabilityMeter(motionManager: motionManager)
    /// Set while a Night capture holds the camera; focus, zoom, lens, mode and drawer
    /// controls wait for it.
    var isNightCapturing = false
    /// Refreshes the Night AUTO label from the capture's plan.
    var nightLabelTask: Task<Void, Never>?
    /// PORTRAIT's depth-effect readiness, running only while PORTRAIT is set up.
    var portraitMonitor: PRMPortraitReadinessMonitor?
    /// Feeds ``portraitStatusPill`` from the monitor while it runs.
    var portraitStatusTask: Task<Void, Never>?

    /// The capture in flight. The shutter ignores taps until it ends.
    var captureTask: Task<Void, Never>?
    var captureGeneration = 0
    var countdownTask: Task<Void, Never>?
    /// Finishes a recording that was running when Studio disappeared.
    var exitTask: Task<Void, Never>?
    var recordingStartedAt: Date?
    var recordingTimerTask: Task<Void, Never>?

    var initialPinchZoom: CGFloat = 1
    /// The zoom the pinch wants next. One drain task applies the newest value, so a fast pinch
    /// never queues stale zoom hops behind each other.
    var pendingZoomTarget: CGFloat?
    var zoomDrainTask: Task<Void, Never>?
    /// The exposure bias when the vertical drag began; the drag offsets it.
    var panStartBias: Float = 0

    /// A tapped lens pill keeps the highlight until this deadline: `videoZoomFactor` changes
    /// at once, but AVFoundation's active constituent lags a few frames behind, and the state
    /// ticks in between would light the previous lens.
    var pinnedActivePill: LensPill?
    var pinnedActivePillUntil: Date?

    /// Camera calls from controls and gestures, latest wins per key.
    let controlRunner = LatestWinsRunner()
    /// Hardware shutter: the Camera Control button on iPhone 16 and later, the volume
    /// buttons, and on iOS 26 a click on an AirPods stem.
    let captureEventHelper = PRMCaptureEventHelper()

    lazy var toaster = ToastPresenter(hostView: view, below: recordingTimerLabel.snp.bottom)

    lazy var drawerControls = StudioDrawerControls(
        camera: camera,
        toast: { [weak self] message in self?.toaster.show(message) },
        prepareForManualExposure: { [weak self] in await self?.prepareForManualExposure() },
        didReturnToAutoExposure: { [weak self] in await self?.restoreVirtualCameraIfFullyAuto() },
        focalLength: { [weak self] zoom in self?.focalLength35mm(forZoom: zoom) ?? 0 },
        maxDimensionsDidChange: { [weak self] isOn in self?.maxDimensionsDidChange(isOn) }
    )

    /// Drawer rows, telemetry badges and overlays for the iOS 26 / 27 capture features.
    lazy var modernControls = ModernCaptureControls(
        camera: camera,
        captureEventHelper: captureEventHelper,
        toast: { [weak self] message in self?.toaster.show(message) },
        prepareForManualExposure: { [weak self] in await self?.prepareForManualExposure() },
        didReturnToAutoExposure: { [weak self] in await self?.restoreVirtualCameraIfFullyAuto() },
        cameraDidChange: { [weak self] in await self?.cinematicVideoDidChangeCamera() }
    )

    // MARK: - Views

    lazy var backButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: "chevron.backward", label: "Back")
        chip.onTap = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        return chip
    }()

    lazy var flashButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: flashSetting.symbol, label: "Flash")
        chip.setActive(flashSetting != .off)
        chip.accessibilityValue = flashSetting.name
        chip.onTap = { [weak self] in self?.cycleFlash() }
        return chip
    }()

    lazy var gridButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: "grid", label: "Grid")
        chip.accessibilityValue = "Off"
        chip.onTap = { [weak self] in self?.cycleGrid() }
        return chip
    }()

    lazy var aspectButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: "aspectratio", label: "Aspect ratio")
        chip.accessibilityValue = "Full sensor"
        chip.onTap = { [weak self] in self?.cycleAspect() }
        return chip
    }()

    lazy var timerButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: TimerSetting.off.symbol, label: "Self-timer")
        chip.accessibilityValue = "Off"
        chip.onTap = { [weak self] in self?.cycleTimer() }
        return chip
    }()

    lazy var settingsButton: ToolbarChip = {
        let chip = ToolbarChip(symbol: "slider.horizontal.3", label: "Camera settings")
        chip.onTap = { [weak self] in self?.toggleDrawer() }
        return chip
    }()

    lazy var topBar: UIStackView = {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [backButton, flashButton, gridButton, aspectButton, timerButton, spacer, settingsButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }()

    lazy var telemetryLabel: PaddedLabel = {
        let label = PaddedLabel()
        label.font = ExampleFont.monospaced(11, weight: .medium, style: .caption2, maximum: 14)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        label.textAlignment = .center
        label.text = "Initializing…"
        label.accessibilityTraits = .updatesFrequently
        return label
    }()

    lazy var lensStrip: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        return stack
    }()

    lazy var modePicker: ModePicker = {
        let picker = ModePicker()
        picker.onChange = { [weak self] primary, variant in
            self?.applyPickerSelection(primary: primary, variant: variant)
        }
        picker.onDisabledVariantTap = { [weak self] message in self?.toaster.show(message) }
        return picker
    }()

    lazy var shutter: PRMShutterButton = {
        let button = PRMShutterButton()
        // Studio plays its own tick when the shutter actually fires (`willCapture`), which
        // also covers the hardware buttons, so the button's tap haptic stays off.
        button.hapticsEnabled = false
        button.onTap = { [weak self] in self?.handleShutterTap() }
        button.onLongPressBegan = { [weak self] in self?.handleShutterLongPressBegan() }
        button.onLongPressEnded = { [weak self] in self?.handleShutterLongPressEnded() }
        return button
    }()

    lazy var switchCameraButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "arrow.triangle.2.circlepath.camera",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Switch camera"
        button.addAction(UIAction { [weak self] _ in self?.requestFlip() }, for: .touchUpInside)
        return button
    }()

    lazy var gridOverlay: PRMGridView = {
        let grid = PRMGridView()
        grid.isGridVisible = false
        grid.isUserInteractionEnabled = false
        return grid
    }()

    lazy var aspectMask: PRMAspectRatioMaskView = {
        let mask = PRMAspectRatioMaskView()
        mask.isUserInteractionEnabled = false
        return mask
    }()

    lazy var levelIndicator: PRMLevelIndicatorView = {
        let indicator = PRMLevelIndicatorView(motionManager: motionManager)
        indicator.lineColor = UIColor.white.withAlphaComponent(0.7)
        indicator.leveledColor = .systemYellow
        indicator.lineWidth = 1.5
        indicator.lineLengthRatio = 0.6
        indicator.hapticsEnabled = true
        indicator.isUserInteractionEnabled = false
        return indicator
    }()

    let focusIndicator = PRMFocusIndicatorView()

    lazy var recordingTimerLabel: PaddedLabel = {
        let label = PaddedLabel()
        label.isHidden = true
        label.textColor = .white
        label.font = ExampleFont.monospaced(13, weight: .semibold, style: .footnote, maximum: 18)
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        label.accessibilityTraits = .updatesFrequently
        return label
    }()

    lazy var countdownLabel: UILabel = {
        let label = UILabel()
        label.isHidden = true
        label.textColor = .systemYellow
        label.font = .systemFont(ofSize: 96, weight: .bold)
        label.textAlignment = .center
        label.accessibilityTraits = .updatesFrequently
        return label
    }()

    let livePill = CapturePill(symbol: "livephoto", tint: .systemYellow, textColor: .black)
    let nightPill = CapturePill(symbol: "moon.stars.fill", tint: .systemIndigo, textColor: .white)
    /// PORTRAIT's depth-effect status, driven by ``portraitMonitor``.
    let portraitStatusPill = StatusPill()

    lazy var drawer: PRMSettingsDrawerView = {
        let drawer = PRMSettingsDrawerView(title: "Camera Settings")
        // Pass touches through while closed; `setOpen(_:animated:)` flips it.
        drawer.isUserInteractionEnabled = false
        return drawer
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        host.delegate = self
        setupLayout()
        wireGestures()
        previewView.addInteraction(captureEventHelper.makeInteraction())
        captureEventHelper.onPrimaryAction = { [weak self] in self?.handleShutterTap() }
        captureEventHelper.onSecondaryAction = { [weak self] in self?.requestFlip() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Studio draws its own top bar (with a back button); the navigation bar comes back as
        // it leaves, and hides again if the user cancels the back swipe.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        levelIndicator.isActive = true
        stabilityMeter.start()
        modernControls.start(previewView: previewView)
        host.viewWillAppear()
        // A mode setup cut short by the last disappearance runs again.
        if host.isBooted, appliedMode != mode {
            scheduleModeChange()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        levelIndicator.isActive = false
        stabilityMeter.stop()
        cancelCountdown()
        zoomDrainTask?.cancel()
        zoomDrainTask = nil
        pendingZoomTarget = nil
        // Mode setups still queued or running stop at their next step; the next appearance
        // sets the mode up again.
        sessionTask?.cancel()
        sessionGeneration += 1
        controlRunner.cancelAll()
        drawerControls.stop()
        modernControls.stop()
        drawer.setOpen(false, animated: false)
        // A capture in flight finishes and saves; a running recording stops and saves. The
        // camera stops once both are done.
        host.viewDidDisappear(awaiting: finishCapturesOnExit())
        stopRecordingTimer()
    }

    deinit {
        sessionTask?.cancel()
        portraitStatusTask?.cancel()
        nightLabelTask?.cancel()
        manualHopTask?.cancel()
        countdownTask?.cancel()
        zoomDrainTask?.cancel()
        recordingTimerTask?.cancel()
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(previewView)
        // Frames arrive in the sensor's orientation; the host rotates (and for the front
        // camera mirrors) the preview, letterboxed to show the whole sensor frame.
        previewView.contentFit = .fit
        let overlays: [UIView] = [
            aspectMask, gridOverlay, levelIndicator, topBar, recordingTimerLabel, livePill, nightPill, countdownLabel,
            telemetryLabel, portraitStatusPill, lensStrip, modePicker, shutter, switchCameraButton, focusIndicator, drawer,
        ]
        overlays.forEach(view.addSubview)

        topBar.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.height.equalTo(44)
        }
        shutter.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-16)
            $0.size.equalTo(CGSize(width: 76, height: 76))
        }
        switchCameraButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().offset(-24)
            $0.centerY.equalTo(shutter)
            $0.size.equalTo(CGSize(width: 44, height: 44))
        }
        modePicker.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.bottom.equalTo(shutter.snp.top).offset(-10)
        }

        // The preview is a 3:4 portrait frame (the sensor's native aspect), as large as fits
        // between the top bar and the mode picker and centered there: an aspect fit, so no
        // screen size can make its constraints conflict.
        let previewArea = UILayoutGuide()
        view.addLayoutGuide(previewArea)
        previewArea.snp.makeConstraints {
            $0.top.equalTo(topBar.snp.bottom).offset(8)
            $0.bottom.equalTo(modePicker.snp.top).offset(-8)
            $0.leading.trailing.equalToSuperview()
        }
        previewView.snp.makeConstraints {
            $0.center.equalTo(previewArea)
            $0.width.equalTo(previewView.snp.height).multipliedBy(3.0 / 4.0)
            $0.width.lessThanOrEqualTo(previewArea)
            $0.height.lessThanOrEqualTo(previewArea)
            $0.width.equalTo(previewArea).priority(.high)
            $0.height.equalTo(previewArea).priority(.high)
        }
        // The crop mask, grid and level follow the image, not the whole screen.
        aspectMask.snp.makeConstraints { $0.edges.equalTo(previewView) }
        gridOverlay.snp.makeConstraints { $0.edges.equalTo(previewView) }
        levelIndicator.snp.makeConstraints {
            $0.center.equalTo(previewView)
            $0.size.equalTo(CGSize(width: 220, height: 220))
        }

        // The recording timer and the LIVE / NIGHT pills are mutually exclusive and share a
        // spot near the top of the image.
        recordingTimerLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.top.equalTo(previewView).offset(12)
        }
        for pill in [livePill, nightPill] {
            pill.snp.makeConstraints { $0.center.equalTo(recordingTimerLabel) }
        }
        countdownLabel.snp.makeConstraints { $0.center.equalTo(previewView) }

        // Lens chips and telemetry sit over the bottom of the image, as in the system Camera.
        lensStrip.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(previewView).offset(-4)
            $0.height.equalTo(44)
        }
        telemetryLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.width.lessThanOrEqualToSuperview().offset(-16)
            $0.bottom.equalTo(lensStrip.snp.top).offset(-4)
        }
        // Where the system Camera shows "NATURAL LIGHT": just above the bottom controls.
        portraitStatusPill.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(telemetryLabel.snp.top).offset(-8)
        }

        drawer.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    private func wireGestures() {
        previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        previewView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        previewView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }
}

// MARK: - CameraPreviewHostDelegate

extension StudioViewController: CameraPreviewHostDelegate {
    func cameraHostConfigure(_ host: CameraPreviewHost) async throws {
        var configuration = PRMCameraConfiguration()
        // Live Photo must be on at configure time to be available at all: the photo output
        // decides at build time whether its pipeline carries the movie path, and no later
        // format change adds it. LIVE then toggles it per mode (`setMovieFileOutputAttached(_:
        // targetLivePhoto:)`), because an *enabled* Live Photo pulls manual exposure and white
        // balance back to auto.
        configuration.includesMovieFileOutput = false
        configuration.enableLivePhoto = true
        configuration.enableDepthDataDelivery = true
        configuration.enablePortraitEffectsMatteDelivery = true
        // Auto-deferred delivery routes depth through the deferred proxy, whose depth map
        // arrives empty on iPhone Pro models; Portrait needs real depth.
        configuration.enableAutoDeferredPhotoDelivery = false
        // Zero shutter lag and responsive capture shoot from pre-fused or in-flight frames,
        // which can still carry auto exposure for seconds after manual exposure is set.
        // AVCamManual turns both off for the same reason.
        configuration.enableResponsiveCapture = false
        configuration.enableZeroShutterLag = false
        // iOS 26: AirPods as a high-quality microphone for recordings.
        configuration.enableBluetoothHighQualityRecording = true
        // No 48MP format at configure: it excludes Live Photo. Max Dimensions switches to it
        // on demand (`setHighResolutionPhotoFormat(_:)`).
        try await host.camera.configure(configuration)
    }

    func cameraHostDidConfigure(_ host: CameraPreviewHost) async {
        let capture = PRMPhotoCapture(session: host.camera.session)
        photoCapture = capture
        nightCapture = PRMNightModeCapture(session: host.camera.session, context: host.renderContext)
        portraitMonitor = PRMPortraitReadinessMonitor(session: host.camera.session)
        rebuildLensStrip()
        populateModeStrip()
        populateDrawer()
    }

    func cameraHostDidStart(_: CameraPreviewHost) async {
        // Set up the current mode on the running session: outputs, frame rate, focal length.
        appliedMode = nil
        scheduleModeChange()
    }

    func cameraHost(_: CameraPreviewHost, didFailToConfigure error: any Error) {
        telemetryLabel.text = "Camera unavailable"
        toaster.report(error, context: "Camera start")
    }

    func cameraHost(_: CameraPreviewHost, didReceive error: PRMSessionError) {
        toaster.report(error, context: "Camera")
    }

    func cameraHost(_: CameraPreviewHost, didUpdate state: PRMCameraState) {
        updateTelemetry(from: state)
    }

    func cameraHost(_: CameraPreviewHost, didChangeInterruption interrupted: Bool) {
        // The reason is in the state by the time the stream yields.
        if interrupted, let reason = camera.state.interruptionReason {
            toaster.show("Session interrupted (\(ModernCaptureControls.name(of: reason)))")
        } else {
            toaster.show(interrupted ? "Session interrupted" : "Session resumed")
        }
    }
}

// MARK: - Lens strip

extension StudioViewController {
    func rebuildLensStrip() {
        lensStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for lens in camera.device?.lenses ?? [] {
            let pill = LensPill(
                title: CaptureLabels.focalLength(lens.snapping().focalLength35mm),
                zoomFactor: lens.zoomFactor,
                deviceType: lens.deviceType,
                kind: lens.kind
            )
            pill.onTap = { [weak self, weak pill] in
                guard let self, let pill else { return }
                selectLens(pill)
            }
            lensStrip.addArrangedSubview(pill)
        }
        refreshActiveLens(from: camera.state)
    }

    /// Highlights `pill`, pins the highlight for a second (see ``pinnedActivePill``) and zooms
    /// to it. Crossing to another physical lens briefly covers the preview, which hides the
    /// frames the previous lens still delivers at digital zoom during the switch.
    func selectLens(_ pill: LensPill) {
        let previous = lensPills.first(where: \.isActive)
        let crossesLens = previous?.deviceType != pill.deviceType && previous?.kind == .physical && pill.kind == .physical
        pinnedActivePill = pill
        pinnedActivePillUntil = Date().addingTimeInterval(1)
        for candidate in lensPills {
            candidate.setActive(candidate === pill)
        }
        if crossesLens {
            showLensSwitchOverlay()
        }
        let zoomFactor = pill.zoomFactor
        controlRunner.run("zoom") { [camera] in await camera.setZoom(zoomFactor) }
    }

    var lensPills: [LensPill] {
        lensStrip.arrangedSubviews.compactMap { $0 as? LensPill }
    }

    /// A brief blur over the preview for the 200 to 300 ms a constituent switch takes, the
    /// cross-fade the system Camera uses.
    private func showLensSwitchOverlay() {
        let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        overlay.alpha = 0.95
        overlay.isUserInteractionEnabled = false
        previewView.addSubview(overlay)
        overlay.snp.makeConstraints { $0.edges.equalToSuperview() }
        UIView.animate(
            withDuration: 0.25,
            delay: 0.2,
            options: [.curveEaseOut],
            animations: { overlay.alpha = 0 },
            completion: { _ in overlay.removeFromSuperview() }
        )
    }

    /// Highlights the pill for the lens actually feeding the preview.
    ///
    /// The zoom bucket comes first (the highest-zoom pill at or below the current zoom), the
    /// only way a sensor-crop pill can light up: AVFoundation reports the underlying wide lens
    /// for both 1× and 2×. Between physical lenses, `activePrimaryDeviceType` then wins, so
    /// when low light keeps the wide lens at 5× the wide pill lights instead of the telephoto.
    func refreshActiveLens(from state: PRMCameraState) {
        let pills = lensPills
        guard !pills.isEmpty else { return }
        if let pinnedActivePill, let until = pinnedActivePillUntil, Date() < until {
            for pill in pills {
                pill.setActive(pill === pinnedActivePill)
            }
            return
        }
        pinnedActivePill = nil
        pinnedActivePillUntil = nil
        let sorted = pills.sorted { $0.zoomFactor < $1.zoomFactor }
        var active = sorted.last { $0.zoomFactor <= state.zoomFactor + 0.001 } ?? sorted.first
        if let bucket = active, bucket.kind == .physical, let activeType = state.activePrimaryDeviceType, activeType != bucket.deviceType,
           let constituent = pills.first(where: { $0.kind == .physical && $0.deviceType == activeType }) {
            active = constituent
        }
        for pill in pills {
            pill.setActive(pill === active)
        }
    }

    /// The 35mm-equivalent focal length for a raw zoom factor, interpolated between the lens
    /// stops' snapped focal lengths so the readout follows a pinch and lands on 13 / 24 /
    /// 120 mm at the stops.
    func focalLength35mm(forZoom zoom: CGFloat) -> Double {
        let sorted = (camera.device?.lenses ?? []).sorted { $0.zoomFactor < $1.zoomFactor }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if zoom <= first.zoomFactor { return first.snapping().focalLength35mm }
        if zoom >= last.zoomFactor {
            // Past the last stop, digital zoom scales that lens's focal length.
            return last.snapping().focalLength35mm * Double(zoom / last.zoomFactor)
        }
        for index in sorted.indices.dropLast() {
            let low = sorted[index]
            let high = sorted[index + 1]
            guard zoom >= low.zoomFactor, zoom <= high.zoomFactor else { continue }
            let lowFocal = low.snapping().focalLength35mm
            // A crop and its lens can share a zoom factor; there's nothing to interpolate.
            guard high.zoomFactor > low.zoomFactor else { return lowFocal }
            let fraction = Double((zoom - low.zoomFactor) / (high.zoomFactor - low.zoomFactor))
            return lowFocal + fraction * (high.snapping().focalLength35mm - lowFocal)
        }
        return first.snapping().focalLength35mm
    }

    /// Zooms to the lens closest to 24mm (the main camera on every iPhone that has one)
    /// through ``selectLens(_:)``, so its pill lights up too. AVFoundation starts virtual
    /// devices on the ultra-wide.
    func applyDefaultFocalLength() async {
        let target: Double = 24
        guard let pick = camera.device?.lenses.min(by: {
            abs($0.snapping().focalLength35mm - target) < abs($1.snapping().focalLength35mm - target)
        }) else { return }
        guard let pill = lensPills.first(where: { abs($0.zoomFactor - pick.zoomFactor) < 0.001 }) else {
            await camera.setZoom(pick.zoomFactor)
            return
        }
        selectLens(pill)
    }
}

// MARK: - Mode picker

extension StudioViewController {
    /// Offers SLO-MO when any camera at the current position has a 120 fps format (on Pro
    /// iPhones only the wide camera does, so entering hops there).
    func populateModeStrip() {
        let position = camera.device?.position ?? .back
        let supportsSlowMo = PRMCameraDevice.anyDeviceSupportsSlowMotion(at: position)
        modePicker.supportsSlowMotion = supportsSlowMo
        if !supportsSlowMo {
            ExampleLog.session.info("Slo-mo hidden: no camera at this position has a 120 fps format")
        }
        syncModePickerAvailability()
    }

    /// Maps a picker selection onto ``mode``: Burst folds into `.photo`, the frame rates into
    /// `.video`, the Night durations into `.night`. Changes that keep the mode (STANDARD to
    /// BURST, 30 to 24 fps) skip the full mode setup.
    func applyPickerSelection(primary: ModePicker.Primary, variant: ModePicker.Variant) {
        ExampleLog.session.notice("Studio picker: \(primary.label, privacy: .public) / \(variant.label, privacy: .public)")
        // The variant row was rebuilt for the new style, which drops per-pill state.
        syncModePickerAvailability()
        burstEnabled = primary == .photo && variant == .burst
        switch primary {
        case .photo:
            setMode(variant == .live ? .live : variant == .portrait ? .portrait : .photo)
        case .video:
            if variant == .slowMo {
                setMode(.slowMo)
                return
            }
            videoFPS = variant == .video24 ? .fps24 : .fps30
            if mode == .video {
                // Same mode, new frame rate: the setup skips everything but the frame rate.
                scheduleModeChange()
            } else {
                setMode(.video)
            }
        case .night:
            nightDuration = switch variant {
            case .night1s: .oneSecond
            case .night3s: .threeSeconds
            case .night5s: .fiveSeconds
            default: .auto
            }
            setMode(.night)
            refreshNightAutoLabel()
        }
    }

    private func setMode(_ target: Mode) {
        guard mode != target else { return }
        mode = target
    }

    /// Dims the variants the configuration excludes. Max Dimensions' 48MP format carries no
    /// movie pipeline, so it rules out Live Photo, Burst and Portrait.
    func syncModePickerAvailability() {
        let message = drawerControls.capMaxDimensions ? "Turn off Max Dimensions to use this mode." : nil
        for variant in [ModePicker.Variant.live, .burst, .portrait] {
            modePicker.setVariantDisabled(variant, message: message)
        }
    }

    /// After a Max Dimensions change lands: gate the excluded modes, and leave one of them
    /// for STANDARD (as the system Camera does), since only a mode change turns the photo
    /// output's Live Photo off.
    func maxDimensionsDidChange(_ isOn: Bool) {
        syncModePickerAvailability()
        guard isOn, mode == .live || mode == .portrait || burstEnabled else { return }
        ExampleLog.session.notice("Studio: Max Dimensions moves \(self.mode.label, privacy: .public) to PHOTO")
        modePicker.select(primary: .photo, variant: .standard)
        applyPickerSelection(primary: .photo, variant: .standard)
    }

    /// Shows the planned capture time on the Night AUTO pill ("AUTO 3s"), from the same plan
    /// the capture uses (scene darkness and whether the phone is still). Re-evaluated on state
    /// ticks so it follows the light.
    func refreshNightAutoLabel() {
        guard mode == .night, !isNightCapturing, let nightCapture else { return }
        let options = PRMNightModeOptions(duration: .automatic, isStable: stabilityMeter.isStable)
        nightLabelTask?.cancel()
        nightLabelTask = Task { [weak self] in
            guard let plan = await nightCapture.plan(options), !Task.isCancelled, let self else { return }
            modePicker.setVariantLabel(for: .nightAuto, to: "AUTO \(Int(plan.duration.rounded()))s")
        }
    }

    /// An AirPods stem click plays the shutter in still modes and begin / end recording in
    /// video modes when custom capture sounds are on (iOS 26).
    func syncCaptureSounds() {
        modernControls.updateCaptureSounds(isVideoMode: mode.isVideo, isRecording: recordingStartedAt != nil)
    }
}

// MARK: - Telemetry

extension StudioViewController {
    func updateTelemetry(from state: PRMCameraState) {
        let readings = [
            mode.label,
            CaptureLabels.focalLength(focalLength35mm(forZoom: state.zoomFactor)),
            "ISO \(Int(state.iso))",
            state.exposureDurationSeconds.map(CaptureLabels.shutter) ?? "auto",
            String(format: "EV %+0.1f", state.exposureBias),
            "\(Int(state.whiteBalanceTemperature))K",
            state.frameRate.map { "\(Int($0))fps" } ?? "",
        ]
        telemetryLabel.text = (readings + modernControls.telemetryBadges(from: state))
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        modernControls.sync(from: state)
        refreshActiveLens(from: state)
        if mode == .night, nightDuration == .auto {
            refreshNightAutoLabel()
        }
        drawerControls.sync(from: state, context: StudioDrawerControls.CaptureContext(
            isRecording: recordingStartedAt != nil,
            isNightMode: mode == .night,
            nightFixesExposure: mode == .night
        ))
    }

    func populateDrawer() {
        guard let device = camera.device else { return }
        drawer.clear()
        for section in drawerControls.makeSections(device: device) + modernControls.makeSections(device: device) {
            drawer.appendSection(title: section.title, rows: section.rows)
        }
        syncModePickerAvailability()
    }
}

// MARK: - Toolbar and gestures

extension StudioViewController {
    func cycleFlash() {
        flashSetting = flashSetting.next
        flashButton.setSymbol(flashSetting.symbol, active: flashSetting != .off)
        flashButton.accessibilityValue = flashSetting.name
    }

    func cycleGrid() {
        gridIndex = (gridIndex + 1) % gridCycle.count
        let type = gridCycle[gridIndex]
        if let type {
            gridOverlay.gridType = type
        }
        gridOverlay.isGridVisible = type != nil
        gridButton.setActive(type != nil)
        gridButton.accessibilityValue = type == nil ? "Off" : "Rule of thirds"
    }

    func cycleAspect() {
        aspectIndex = (aspectIndex + 1) % aspectCycle.count
        let ratio = aspectCycle[aspectIndex]
        aspectMask.aspectRatio = ratio
        aspectButton.setActive(ratio != .unconstrained)
        aspectButton.accessibilityValue = switch ratio {
        case .ratio4x3: "4 by 3"
        case .ratio16x9: "16 by 9"
        case .ratio1x1: "Square"
        case .unconstrained: "Full sensor"
        }
    }

    func cycleTimer() {
        timerSetting = timerSetting.next
        timerButton.setSymbol(timerSetting.symbol, active: timerSetting != .off)
        timerButton.accessibilityValue = timerSetting == .off ? "Off" : "\(timerSetting.rawValue) seconds"
    }

    func toggleDrawer() {
        guard !isNightCapturing else { return }
        drawer.setOpen(!drawer.isOpen, animated: true)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !isNightCapturing else { return }
        // Both the indicator and the device point use preview coordinates, so the indicator
        // lands under the finger.
        let previewPoint = gesture.location(in: previewView)
        let devicePoint = previewView.texturePoint(fromViewPoint: previewPoint)
        focusIndicator.show(at: previewPoint, in: previewView)
        // Point focus by default; rect focus, tap-to-track (iOS 27) and Cinematic Video's
        // tracking focus (iOS 26) are routed by the modern controls.
        controlRunner.run("focus") { [weak self] in await self?.modernControls.focus(atDevicePoint: devicePoint) }
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isNightCapturing else { return }
        switch gesture.state {
        case .began:
            initialPinchZoom = camera.state.zoomFactor
        case .changed:
            // Exponential mapping: perceived zoom is logarithmic, so the 1.5 exponent gives
            // fine steps near 1× while a fast pinch still reaches 10×.
            pendingZoomTarget = initialPinchZoom * pow(gesture.scale, 1.5)
            startZoomDrainIfNeeded()
        default:
            break
        }
    }

    /// Applies the newest pinch target, then checks for a newer one, until none is left.
    private func startZoomDrainIfNeeded() {
        guard zoomDrainTask == nil else { return }
        zoomDrainTask = Task { [weak self] in
            while let self, let target = pendingZoomTarget, !Task.isCancelled {
                pendingZoomTarget = nil
                await camera.setZoom(target)
            }
            self?.zoomDrainTask = nil
        }
    }

    /// A vertical drag offsets the exposure bias it started from: a full half-screen drag up
    /// is +2 EV.
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panStartBias = camera.state.exposureBias
        case .changed:
            let travel = gesture.translation(in: view).y / max(view.bounds.height / 2, 1)
            var bias = panStartBias - Float(travel * 2)
            if let range = camera.device?.exposureBiasRange {
                bias = min(max(bias, range.lowerBound), range.upperBound)
            }
            let target = bias
            controlRunner.run("exposureBias") { [camera] in await camera.setExposureBias(target) }
        default:
            break
        }
    }
}
