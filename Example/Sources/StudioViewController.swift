// Example demo screen — exercises the full Prism API surface in a single VC, so the
// file and class are larger than a production screen would be. Length-based lint rules
// don't add signal here.
// swiftlint:disable file_length type_body_length

@preconcurrency import AVFoundation
import ImageIO
import Photos
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - StudioViewController

/// A DSLR-style camera app: live preview, focal-length lens picker, telemetry strip,
/// photo / live / portrait / pano / video / slow-mo / night modes, tap-to-focus,
/// pinch-to-zoom, drag-to-bias-exposure, hardware capture controls, full settings drawer.
///
/// Exercises the full PrismCore + PrismUI surface in one screen.
@MainActor
final class StudioViewController: UIViewController {
    // MARK: - Camera

    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    /// `PRMRenderContext()` only fails when the device has no Metal support, which is
    /// terminal for a Metal-backed preview — no graceful fallback is possible.
    private let renderContext: PRMRenderContext = {
        guard let context = PRMRenderContext() else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var previewView = PRMPreviewView(context: renderContext)
    private var photoCapture: PRMPhotoCapture?
    private var videoRecorder: PRMVideoRecorder?
    private var nightCapture: PRMNightModeCapture?

    // MARK: - UI

    private let topBar = UIStackView()
    private let telemetryLabel = PaddedLabel()
    private let lensStrip = UIStackView()
    private let modePicker = ModePicker()
    private let shutter = PRMShutterButton()
    private let switchCameraButton = UIButton(type: .system)
    private let gridOverlay = PRMGridView()
    private let aspectMask = PRMAspectRatioMaskView()
    private let levelIndicator = PRMLevelIndicatorView()
    private let focusIndicator = PRMFocusIndicatorView()
    private let recordingTimerLabel = PaddedLabel()
    private let countdownLabel = UILabel()
    private let flashButton = ToolbarChip(symbol: "bolt.badge.a.fill")
    private let gridButton = ToolbarChip(symbol: "grid")
    private let aspectButton = ToolbarChip(symbol: "aspectratio")
    private let timerButton = ToolbarChip(symbol: "timer")
    private let settingsButton = ToolbarChip(symbol: "slider.horizontal.3")
    private let liveIndicator = LiveCaptureIndicator()
    private let nightIndicator = NightCaptureIndicator()
    private let drawer = PRMSettingsDrawerView(title: "Camera Settings")

    // MARK: - State

    private enum Mode: Equatable {
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
    }

    private var mode: Mode = .photo {
        didSet { applyModeChange(from: oldValue) }
    }

    private var aspectIndex = 0
    private let aspectCycle: [PRMAspectRatioMaskView.AspectRatio] = [.unconstrained, .ratio4x3, .ratio16x9, .ratio1x1]

    private var gridIndex = 0
    private let gridCycle: [PRMGridView.GridType?] = [nil, .ruleOfThirds]

    private enum FlashSetting {
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

        var avMode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        }
    }

    private enum TimerSetting: Int, CaseIterable {
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

    /// Night mode capture duration. `.auto` lets the controller pick from current ISO and
    /// shutter telemetry (Apple Camera's behavior); the explicit values let the user
    /// override the auto pick the same way Apple's slide-shutter does.
    private enum NightDuration: Equatable {
        case auto
        case oneSecond
        case threeSeconds
        case fiveSeconds

        var label: String {
            switch self {
            case .auto: "AUTO"
            case .oneSecond: "1s"
            case .threeSeconds: "3s"
            case .fiveSeconds: "5s"
            }
        }

        /// (frameCount, perFrameDuration, iso) for `PRMNightModeCapture.capture`.
        var capture: (frames: Int, perFrame: Double, iso: Float) {
            switch self {
            case .auto, .oneSecond: (frames: 4, perFrame: 0.25, iso: 800)
            case .threeSeconds: (frames: 6, perFrame: 0.5, iso: 1600)
            case .fiveSeconds: (frames: 10, perFrame: 0.5, iso: 1600)
            }
        }

        var next: Self {
            switch self {
            case .auto: .oneSecond
            case .oneSecond: .threeSeconds
            case .threeSeconds: .fiveSeconds
            case .fiveSeconds: .auto
            }
        }
    }

    /// Cinematic-style frame-rate variants under VIDEO. 24 fps gives a film cadence, 30
    /// matches the iOS Camera default. 60 fps was intentionally dropped from the picker:
    /// the camera's `.photo` session preset uses a 4:3 sensor format whose frame-rate
    /// range tops out at 30 fps, so 60 fps forces a switch to a 16:9 video format with
    /// narrower FoV — the preview visibly resizes, and the Metal pipeline adds latency
    /// during the format renegotiation. Higher temporal resolutions are still available
    /// via the SLO-MO variant (120/240 fps, expected to look different to users).
    private enum VideoFPS: Equatable {
        case fps24, fps30

        var value: Float64 {
            switch self {
            case .fps24: 24
            case .fps30: 30
            }
        }

        var label: String {
            switch self {
            case .fps24: "24"
            case .fps30: "30"
            }
        }
    }

    private var flashSetting: FlashSetting = .auto
    private var timerSetting: TimerSetting = .off
    private var burstEnabled = false
    private var nightDuration: NightDuration = .auto
    private var videoFPS: VideoFPS = .fps30
    private var initialPinchZoom: CGFloat = 1.0
    /// Latest zoom target the pinch handler wants. A single drain task picks up whichever
    /// value is most recent, skipping intermediate values the finger has already pinched
    /// past. Without coalescing, UIPinchGestureRecognizer fires `.changed` at ~60Hz and
    /// each event enqueued its own actor hop — the actor processed them in order, so a
    /// fast pinch produced visible stepping as stale targets fired before the newest
    /// one. With coalescing, queue depth stays at 1.
    private var pendingZoomTarget: CGFloat?
    private var zoomDrainTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    private var lastDevice: PRMCameraDevice?

    // MARK: - Drawer row handles

    //
    // Kept so sliders / segmented controls can be cross-synced from `updateTelemetry` and
    // from each other — e.g. dragging ISO promotes the exposure-mode segmented to "Custom",
    // picking the Day/Indoor/Night preset updates the ISO + shutter sliders, the state-
    // stream tick keeps every widget aligned with AVFoundation's actual mode after
    // auto-mode drift.

    private var exposureModeSegmented: UISegmentedControl?
    private var evRow: PRMSettingsRow?
    private var evSlider: UISlider?
    private var isoRow: PRMSettingsRow?
    private var isoSlider: UISlider?
    private var shutterRow: PRMSettingsRow?
    private var shutterSlider: UISlider?
    /// User-facing stops, in seconds. Filled in by `makeShutterRow` to match the active
    /// format's supported range so the slider can't land on a value the device will
    /// silently clamp out from under us.
    private var shutterStops: [Double] = []
    private var customExposureSegmented: UISegmentedControl?
    private var wbModeSegmented: UISegmentedControl?
    private var wbRow: PRMSettingsRow?
    private var wbKelvinSlider: UISlider?
    private var focusModeSegmented: UISegmentedControl?
    private var focusRow: PRMSettingsRow?
    private var lensSlider: UISlider?
    /// Max Dimensions row + its toggle. Tracked so `syncMaxDimensionsRow(from:)` can
    /// flip the disabled state when the active device's largest supported photo
    /// dimensions don't exceed 12MP (virtual devices like `.builtInTripleCamera`).
    private var maxDimensionsRow: PRMSettingsRow?
    private var maxDimensionsToggle: UISwitch?
    /// Set while a programmatic slider / segmented update is in flight so the
    /// `.valueChanged` action doesn't re-fire the underlying camera setter. Prevents a
    /// feedback loop when the state-stream sync writes back into the same control that
    /// originated the change.
    private var isApplyingExternalUpdate = false

    /// Drives `PRMCamera.rampZoom` / `.cancelZoomRamp` — smooth 1.0×→2.0× ramp at rate 1.0.
    fileprivate var isZoomRamping = false

    /// Set when the user taps a lens chip — pins the highlight to that pill until
    /// AVFoundation's `activePrimaryConstituent` catches up. `videoZoomFactor` updates
    /// instantly but the constituent-device resolution lags by a few frames, so without
    /// this pin the state-stream tick can briefly revert the highlight to the *previous*
    /// lens (the stale active constituent) before settling on the correct one.
    private var pinnedActivePill: LensPill?
    /// Wall-clock deadline for the pin. Once `Date() >= this`, the pin is dropped and
    /// `refreshActiveLens` resumes following live AVFoundation state.
    private var pinnedActivePillUntil: Date?

    private var rotationStreamTask: Task<Void, Never>?

    // Error + interruption observers (toasts surfaced via showToast).
    private var errorStreamTask: Task<Void, Never>?
    private var interruptionStreamTask: Task<Void, Never>?
    private var stateStreamTask: Task<Void, Never>?

    /// Polls `camera.refreshState()` at 2Hz so the telemetry label reflects auto-driven
    /// changes (ISO drift under auto-exposure, white-balance temperature drift, lens
    /// position) that AVFoundation mutates continuously without going through a setter.
    /// Without this tick the label would only update when the user pinches, taps a lens,
    /// or otherwise calls a `PRMCamera` mutator that triggers `refreshState` itself.
    private var telemetryTickTask: Task<Void, Never>?

    /// Hardware shutter (Camera Control button on iPhone 16+, volume buttons elsewhere).
    private let captureEventHelper = PRMCaptureEventHelper()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Example app: turn on Prism's verbose SDK traces so the Console.app log shows
        // every configure / start / switchCamera / setter / format-swap / capture entry.
        // SDK callers ship with this off — flipping it on here keeps the example useful
        // as a "what's actually happening under the hood?" debugging surface without
        // making release builds chatty.
        PRMLogger.isVerboseTracingEnabled = true

        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationController?.setNavigationBarHidden(true, animated: false)
        modalPresentationCapturesStatusBarAppearance = true

        setupLayout()
        wireGestures()
        previewView.addInteraction(captureEventHelper.makeInteraction())
        captureEventHelper.onPrimaryAction = { [weak self] in self?.handleShutterTap() }
        captureEventHelper.onSecondaryAction = { [weak self] in self?.flipCameraSync() }
        PRMLogger.session.notice("Studio viewDidLoad — verbose tracing enabled")
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        rotationStreamTask?.cancel()
        errorStreamTask?.cancel()
        interruptionStreamTask?.cancel()
        stateStreamTask?.cancel()
        telemetryTickTask?.cancel()
        rotationStreamTask = nil
        errorStreamTask = nil
        interruptionStreamTask = nil
        stateStreamTask = nil
        telemetryTickTask = nil
        Task { await camera.stop() }
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func flipCameraSync() {
        Task { await flipCamera() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Layout

    private func setupLayout() {
        // Preview is bounded *above* the mode picker so the bottom UI strip (lens row,
        // mode picker, shutter, telemetry) sits on a black bar instead of overlapping the
        // preview frame. The bottom constraint is wired after `modePicker` is added below
        // (in this same method) via SnapKit closures.
        view.addSubview(previewView)
        // Preview frames arrive pre-rotated via the data-output connection's
        // `videoRotationAngle`, set from `PRMRotationCoordinator` in `bootCamera()`.
        // MTKView itself renders identity.
        // Letterbox the full sensor frame instead of cropping to the view aspect.
        previewView.contentFit = .fit

        // Aspect mask + grid overlay match the preview frame, not the whole view, so
        // crop guides and rule-of-thirds align with the actual visible image.
        view.addSubview(aspectMask)
        view.addSubview(gridOverlay)
        gridOverlay.isGridVisible = false

        levelIndicator.lineColor = UIColor.white.withAlphaComponent(0.7)
        levelIndicator.leveledColor = .systemYellow
        levelIndicator.lineWidth = 1.5
        view.addSubview(levelIndicator)
        levelIndicator.lineLengthRatio = 0.6
        levelIndicator.snp.makeConstraints {
            // Centered within the preview frame, not the whole view, so the line stays
            // visually anchored to the image as the preview shrinks above the mode picker.
            $0.center.equalTo(previewView)
            $0.width.equalTo(220)
            $0.height.equalTo(220)
        }
        levelIndicator.isActive = true

        topBar.axis = .horizontal
        topBar.spacing = 12
        topBar.alignment = .center
        view.addSubview(topBar)
        topBar.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(40)
        }
        flashButton.onTap = { [weak self] in self?.cycleFlash() }
        gridButton.onTap = { [weak self] in self?.cycleGrid() }
        aspectButton.onTap = { [weak self] in self?.cycleAspect() }
        timerButton.onTap = { [weak self] in self?.cycleTimer() }
        settingsButton.onTap = { [weak self] in self?.toggleDrawer() }
        topBar.addArrangedSubview(flashButton)
        topBar.addArrangedSubview(gridButton)
        topBar.addArrangedSubview(aspectButton)
        topBar.addArrangedSubview(timerButton)
        let topBarSpacer = UIView()
        topBarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(topBarSpacer)
        topBar.addArrangedSubview(settingsButton)

        recordingTimerLabel.isHidden = true
        recordingTimerLabel.textColor = .white
        recordingTimerLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        recordingTimerLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        view.addSubview(recordingTimerLabel)
        // Anchored well below the top bar to clear the chip row visually.
        // `recordingTimerLabel`, `liveIndicator`, and `nightIndicator` are mutually
        // exclusive (video uses one, Live Photo a second, Night the third) and share the
        // same centerX + centerY so they swap in place.
        recordingTimerLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.top.equalTo(topBar.snp.bottom).offset(48)
            $0.height.equalTo(28)
        }

        view.addSubview(liveIndicator)
        liveIndicator.snp.makeConstraints {
            $0.centerX.equalTo(recordingTimerLabel)
            $0.centerY.equalTo(recordingTimerLabel)
            $0.height.equalTo(28)
        }

        view.addSubview(nightIndicator)
        nightIndicator.snp.makeConstraints {
            $0.centerX.equalTo(recordingTimerLabel)
            $0.centerY.equalTo(recordingTimerLabel)
            $0.height.equalTo(28)
        }

        countdownLabel.isHidden = true
        countdownLabel.textColor = .systemYellow
        countdownLabel.font = .systemFont(ofSize: 96, weight: .bold)
        countdownLabel.textAlignment = .center
        view.addSubview(countdownLabel)
        countdownLabel.snp.makeConstraints { $0.center.equalToSuperview() }

        telemetryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        telemetryLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        telemetryLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        telemetryLabel.textAlignment = .center
        telemetryLabel.text = "Initializing…"
        view.addSubview(telemetryLabel)

        lensStrip.axis = .horizontal
        lensStrip.spacing = 10
        lensStrip.alignment = .center
        lensStrip.distribution = .equalSpacing
        view.addSubview(lensStrip)

        view.addSubview(modePicker)
        modePicker.onChange = { [weak self] primary, variant in
            self?.applyModeChange(primary: primary, variant: variant)
        }
        modePicker.onDisabledVariantTap = { [weak self] message in
            self?.showToast(message)
        }

        view.addSubview(shutter)
        view.addSubview(switchCameraButton)
        let flipSymbol = UIImage(
            systemName: "arrow.triangle.2.circlepath.camera",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        switchCameraButton.setImage(flipSymbol, for: .normal)
        switchCameraButton.tintColor = .white
        switchCameraButton.imageView?.contentMode = .scaleAspectFit
        switchCameraButton.addAction(UIAction { [weak self] _ in
            Task { await self?.flipCamera() }
        }, for: .touchUpInside)

        shutter.onTap = { [weak self] in self?.handleShutterTap() }
        shutter.onLongPressBegan = { [weak self] in self?.handleShutterLongPressBegan() }
        shutter.onLongPressEnded = { [weak self] in self?.handleShutterLongPressEnded() }
        shutter.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-16)
            $0.size.equalTo(CGSize(width: 76, height: 76))
        }

        switchCameraButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().offset(-30)
            $0.centerY.equalTo(shutter)
            $0.size.equalTo(CGSize(width: 32, height: 32))
        }

        modePicker.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.bottom.equalTo(shutter.snp.top).offset(-14)
        }

        // Preview is centered vertically in the screen with a fixed 4:3 portrait aspect
        // ratio (matches the iPhone sensor's native crop). A small upward `centerY.offset`
        // lifts it above the geometric middle so the heavier bottom chrome (lens strip +
        // mode picker + shutter) feels visually balanced. It floats independent of the
        // top bar and mode picker — both can grow/shrink without dragging the preview
        // off-center. The .lessThanOrEqualTo guards keep it inside the available space
        // if the screen is short enough that the centered frame would overlap chrome.
        // The lens strip (xx mm chips) and telemetry label paint on top of the preview
        // (added to the view hierarchy after `previewView`), matching Apple's layout.
        previewView.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.centerY.equalToSuperview().offset(-40)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(previewView.snp.width).multipliedBy(4.0 / 3.0)
            $0.top.greaterThanOrEqualTo(topBar.snp.bottom).offset(8)
            $0.bottom.lessThanOrEqualTo(modePicker.snp.top).offset(-8)
        }
        aspectMask.snp.makeConstraints { $0.edges.equalTo(previewView) }
        gridOverlay.snp.makeConstraints { $0.edges.equalTo(previewView) }

        lensStrip.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(modePicker.snp.top).offset(-12)
            $0.height.equalTo(36)
        }

        telemetryLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(lensStrip.snp.top).offset(-12)
            $0.height.equalTo(26)
        }

        view.addSubview(focusIndicator)

        view.addSubview(drawer)
        drawer.snp.makeConstraints { $0.edges.equalToSuperview() }
        drawer.isUserInteractionEnabled = false  // pass through when closed
    }

    private func wireGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        previewView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        previewView.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        previewView.addGestureRecognizer(pan)
    }

    // MARK: - Boot

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        if PRMPermissions.microphoneStatus() == .notDetermined {
            _ = await PRMPermissions.requestMicrophoneAccess()
        }

        do {
            var config = PRMCameraConfiguration()
            // **`enableLivePhoto` MUST be true at configure time** if Live Photo is ever
            // going to be tapped at runtime. Per Apple's docs
            // (developer.apple.com/documentation/avfoundation/avcapturephotooutput/
            // islivephotocapturesupported): "Live Photo capture requires a lengthy
            // reconfiguration of the capture render pipeline, so if you intend to do any
            // Live Photo captures at all, you should set livePhotoCaptureEnabled to YES
            // *before calling -[AVCaptureSession startRunning]*." The pipeline's secondary
            // movie-capture path is decided at build time; no runtime format swap can
            // retroactively add it — `isLivePhotoCaptureSupported` stays false forever
            // for sessions that started without it (verified empirically: iterating all
            // 12 formats on Triple camera, every single one reports
            // isLivePhotoCaptureSupported=false when the pipeline was built with
            // enableLivePhoto=false).
            //
            // The per-frame runtime knob `setLivePhotoCaptureEnabled(_:)` is still needed
            // for manual-exposure modes — Live Photo *enabled* (not supported) at the
            // photo output silently reverts `device.exposureMode = .custom` and WB lock
            // back to continuous-auto within a frame or two (the photo output requires
            // the sensor in auto pipeline to bracket the Live Photo movie). So Studio's
            // `applyModeChange()` flips `setLivePhotoCaptureEnabled(true)` in Live mode
            // and `false` everywhere else. That toggle is cheap when the pipeline already
            // has the support wired; what we cannot do is *add* support at runtime.
            config.includesMovieFileOutput = false
            config.enableLivePhoto = true
            config.enableDepthDataDelivery = true
            config.enablePortraitEffectsMatteDelivery = true
            // Auto-deferred photo delivery conflicts with depth/matte on iPhone Pro
            // models: AVFoundation routes the depth XPC stream through the deferred
            // proxy and the proxy callback's `depthData` arrives with an internally
            // null `depthDataMap`. Visible as the FigXPCUtilities -17281 / "buffer is
            // nil" errors on iPhone 15 Pro Max in Portrait mode. Disable deferred
            // delivery in this example so portrait actually produces depth — apps
            // that don't need depth can opt back in via `PRMCameraConfiguration`.
            config.enableAutoDeferredPhotoDelivery = false
            // Responsive Capture and Zero Shutter Lag both fight manual
            // exposure on iPhone 14 Pro+: ZSL maintains a ring buffer of
            // pre-shutter frames that AVFoundation pre-stabilizes via Smart
            // HDR / Deep Fusion (so the photo at shutter time draws from a
            // fused, multi-exposure pre-capture), and Responsive Capture
            // overlaps frame processing so the in-flight frame at shutter time
            // may belong to a *prior* auto-exposure pipeline state even after
            // the user committed manual. Per WWDC23 session 10105, ZSL is
            // documented to auto-disable for manual exposure — but the auto-
            // disable only kicks in once `device.exposureMode == .custom` has
            // committed on the *device*, which has a ~3 s lag (dev-forum
            // 751112). For a Studio-style app the user pays nothing for going
            // without ZSL / Responsive (the manual-shutter cadence is the
            // bottleneck, not pipeline latency) and gets reliably-honored
            // manual exposure in return. AVCamManual disables both for the
            // same reason.
            config.enableResponsiveCapture = false
            config.enableZeroShutterLag = false
            // Don't pre-promote to the 48MP format at configure time — that format is
            // mutually exclusive with Live Photo. Studio toggles Max Dimensions per user
            // action via `camera.setHighResolutionPhotoFormat(_:)`, which flips formats
            // on demand. Configure leaves us in the default `.photo` preset format,
            // which supports Live Photo + burst + depth.
            try await camera.configure(config)
        } catch {
            PRMLogger.session.error("Camera configure failed: \(String(describing: error), privacy: .public)")
            showAlert(title: "Cannot start camera", message: error.localizedDescription)
            return
        }

        // Portrait baseline. `PRMRotationCoordinator` only updates this on real devices —
        // the simulator has no gyroscope (CoreMotion is unavailable), so
        // `videoRotationAngleForHorizonLevelPreview` would stay at 0 (raw sensor
        // landscape) and the preview would look 90° CCW rotated in portrait. Seeding 90°
        // here pre-rotates every CVPixelBuffer to gravity-aligned portrait so MTKView
        // can render identity; on real hardware the coordinator stream overrides this
        // as the device tilts.
        await applyConnectionRotation(90)

        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.previewView.update(frame.pixelBuffer)
        }

        await PRMCameraActor.shared.run {
            if let photoOutput = await self.camera.session.photoOutput {
                let capture = PRMPhotoCapture(output: photoOutput)
                let context = self.renderContext
                await MainActor.run {
                    self.photoCapture = capture
                    self.nightCapture = PRMNightModeCapture(capture: capture, context: context)
                }
            }
            // Use the session-based init so the recorder transparently survives
            // format-swap-driven movie output replacements (e.g. slo-mo activation
            // re-attaches the output internally). The recorder resolves
            // `session.movieFileOutput` afresh at every `start()` call.
            await MainActor.run {
                self.videoRecorder = PRMVideoRecorder(session: self.camera.session)
            }
        }

        rebuildLensStrip()
        populateModeStrip()
        populateDrawer()

        // PRMCamera state stream — drives the telemetry strip.
        stateStreamTask = Task { [weak self] in
            guard let self else { return }
            for await state in camera.stateStream() {
                guard !Task.isCancelled else { break }
                updateTelemetry(from: state)
            }
        }

        // PRMCamera error stream — surface AVFoundation runtime errors as a toast.
        errorStreamTask = Task { [weak self] in
            guard let self else { return }
            for await error in camera.errorStream() {
                guard !Task.isCancelled else { break }
                reportError(error, context: "Runtime")
            }
        }

        // PRMCamera interruption stream — phone calls, Control Center pip, etc.
        interruptionStreamTask = Task { [weak self] in
            guard let self else { return }
            for await interrupted in camera.interruptionStream() {
                guard !Task.isCancelled else { break }
                showToast(interrupted ? "Session interrupted" : "Session resumed")
            }
        }

        // 2Hz telemetry refresh tick. AVFoundation continuously updates `iso`,
        // `exposureDuration`, `whiteBalanceGains`, etc. under auto modes — but
        // `PRMCamera.refreshState` only fires when a setter is called. Without this
        // tick the telemetry label freezes on whatever values were captured at the
        // most recent user action (so on first open ISO is stuck at the cold-start
        // value even as the device adjusts to the actual scene).
        telemetryTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { break }
                await camera.refreshState()
            }
        }

        await rebindRotationCoordinator()

        await camera.start()
        await applyDefaultFocalLength()
    }

    /// Holds the current rotation coordinator so it can be torn down + replaced on
    /// camera switch. Reassigning to a new coordinator (in `rebindRotationCoordinator`)
    /// drops the previous one — its KVO observations stop, its continuations finish, and
    /// the old rotation stream task exits.
    private var rotationCoordinator: PRMRotationCoordinator?

    /// Tears down the previous coordinator + stream task and binds a fresh
    /// `PRMRotationCoordinator` to the *current* `camera.session.videoDevice`. Each
    /// emitted angle gets applied to the data-output connection's `videoRotationAngle`
    /// — AVFoundation then pre-rotates every CVPixelBuffer so MTKView can render
    /// identity. Same path `AVCaptureVideoPreviewLayer` takes internally. Call after
    /// the device changes (initial boot, `flipCamera`).
    ///
    /// On the simulator the coordinator emits 0 (no gyroscope), so the explicit
    /// `applyConnectionRotation(90)` baseline at boot keeps the preview upright.
    private func rebindRotationCoordinator() async {
        rotationStreamTask?.cancel()
        rotationStreamTask = nil
        rotationCoordinator = nil

        guard let device = await camera.session.videoDevice else { return }
        let coordinator = PRMRotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationStreamTask = Task { [weak self] in
            for await angle in coordinator.previewRotationAngles() {
                guard !Task.isCancelled, let self else { break }
                // Coordinator returns 0 on the simulator (no CoreMotion). Don't let it
                // overwrite the 90° portrait baseline seeded at configure time.
                guard angle != 0 else { continue }
                await applyConnectionRotation(angle)
            }
        }
    }

    /// Sets `videoRotationAngle` on the video-data-output connection inside a
    /// `beginConfiguration`/`commitConfiguration` block (the Apple-recommended pattern).
    /// Hop through `PRMCameraActor` since `AVCaptureSession` mutations must serialize there.
    private func applyConnectionRotation(_ angle: CGFloat) async {
        let session = camera.session
        await PRMCameraActor.shared.run {
            guard let connection = await session.videoDataOutput?.connection(with: .video) else { return }
            guard connection.isVideoRotationAngleSupported(angle) else { return }
            session.session.beginConfiguration()
            connection.videoRotationAngle = angle
            session.session.commitConfiguration()
        }
    }

    // MARK: - Lens strip

    private func rebuildLensStrip() {
        lensStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lenses = camera.device?.lenses ?? []
        for lens in lenses {
            let snappedFocal = lens.snapping().focalLength35mm
            let button = LensPill(
                title: "\(Int(snappedFocal))mm",
                zoomFactor: lens.zoomFactor,
                displayZoomFactor: lens.displayZoomFactor,
                deviceType: lens.deviceType,
                kind: lens.kind
            )
            button.onTap = { [weak self, weak button] in
                guard let self, let button else { return }
                selectLens(button: button, zoomFactor: lens.zoomFactor)
            }
            lensStrip.addArrangedSubview(button)
        }
        refreshActiveLens(from: camera.state)
    }

    /// Pin the highlight to `button` and dispatch the underlying `setZoom`. Used by
    /// both the tap handler and the `applyDefaultFocalLength` startup path so the
    /// default 24mm chip lights up on first boot too.
    ///
    /// The pin protects the highlight from being clobbered by the state-stream tick that
    /// fires immediately after `setZoom`: `videoZoomFactor` updates synchronously, but
    /// AVFoundation's `activePrimaryConstituent` lags by a few frames. Without the pin
    /// the tick reads a stale constituent and the highlight reverts to the previous lens.
    ///
    /// When the new pill represents a different physical lens than the current one, also
    /// shows `lensSwitchOverlay` briefly to mask the visible "previous lens does digital
    /// zoom" artifact during the constituent switch. Same-lens taps skip the overlay.
    private func selectLens(button: LensPill, zoomFactor: CGFloat) {
        let previouslyActive = (lensStrip.arrangedSubviews.compactMap { $0 as? LensPill })
            .first(where: \.isActive)
        // Skip the overlay when either pill is a sensor crop — the physical lens isn't
        // changing, so the "previous lens does digital zoom" artifact the overlay masks
        // doesn't exist. Crossing a deviceType boundary only matters between physical
        // lenses (e.g. wide → telephoto).
        let crossesLens = previouslyActive?.deviceType != button.deviceType
            && previouslyActive?.kind == .physical
            && button.kind == .physical

        pinnedActivePill = button
        pinnedActivePillUntil = Date().addingTimeInterval(1.0)
        let pills = lensStrip.arrangedSubviews.compactMap { $0 as? LensPill }
        for pill in pills {
            pill.setActive(pill === button)
        }
        if crossesLens {
            showLensSwitchOverlay()
        }
        Task { await camera.setZoom(zoomFactor) }
    }

    /// Brief blur overlay over the preview that masks the ~200-300ms constituent-switch
    /// transition. AVFoundation updates `videoZoomFactor` synchronously, but in-flight
    /// frames from the *previous* constituent show as digital zoom on that lens before
    /// the actual lens switch lands. Covering the preview during the transition is what
    /// makes the change look instant — matches the cross-fade Apple Camera uses.
    private func showLensSwitchOverlay() {
        let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        overlay.alpha = 0.95
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

    /// Highlights the lens pill that is *physically* feeding the preview right now.
    ///
    /// Preferred path (iOS 16+ on virtual devices): match by
    /// `state.activePrimaryDeviceType` — AVFoundation reports which constituent lens it
    /// has selected, including runtime fallbacks (low light, close subject, etc.) where
    /// it sticks with wide even though the user picked telephoto.
    ///
    /// Fallback (single-lens devices, simulator, or pre-resolve): use the switchover
    /// bucket — `PRMLens` entries are sorted by raw `zoomFactor`, and AVFoundation
    /// hands frames from the highest-zoom lens whose `zoomFactor ≤ currentZoom`.
    private func refreshActiveLens(from state: PRMCameraState) {
        let pills = lensStrip.arrangedSubviews.compactMap { $0 as? LensPill }
        guard !pills.isEmpty else { return }

        // Honor the most recent tap for a short window while AVFoundation's
        // `activePrimaryConstituent` catches up to the new `videoZoomFactor`. Without
        // this, the state-stream tick that fires immediately after `setZoom` would see
        // the *stale* constituent device and revert the highlight to the previous lens
        // until a later tick. The pin times itself out so pinch / hardware zoom paths
        // still flow through to the live AVFoundation match.
        if let pinnedPill = pinnedActivePill,
           let until = pinnedActivePillUntil,
           Date() < until {
            for pill in pills {
                pill.setActive(pill === pinnedPill)
            }
            return
        }
        // Pin expired — drop the reference so we stop comparing against it.
        pinnedActivePill = nil
        pinnedActivePillUntil = nil

        // Resolve via the zoom-factor bucket first — this is the only way virtual
        // sensor-crop chips (deviceType == nil, zoomFactor above the wide they crop
        // from) can light up at 2× and beyond, since AVFoundation's
        // `activePrimaryDeviceType` reports the underlying physical lens (wide) for
        // both 1× and 2× on those devices. The sorted-bucket approach finds the
        // highest-`zoomFactor` chip whose factor is ≤ current zoom.
        //
        // Then, on Pro devices with multiple physical lenses and a low-light fallback
        // (user picks 5× telephoto, AVFoundation refuses and silently stays on wide
        // with digital zoom), prefer the `activePrimaryDeviceType` match so the wide
        // pill lights up instead of the telephoto — gives the user a visible signal
        // that the requested switch didn't happen. The override only applies between
        // *physical* chips; crops have no constituent device so they always win the
        // zoom-bucket bid for their factor band.
        let sorted = pills.sorted { $0.zoomFactor < $1.zoomFactor }
        var active = sorted.last { $0.zoomFactor <= state.zoomFactor + 0.001 } ?? sorted.first
        if let bucket = active, bucket.kind == .physical, let activeType = state.activePrimaryDeviceType,
           activeType != bucket.deviceType,
           let constituentMatch = pills.first(where: { $0.kind == .physical && $0.deviceType == activeType }) {
            active = constituentMatch
        }
        for pill in pills {
            pill.setActive(pill === active)
        }
    }

    /// 35mm-equivalent focal length for an arbitrary raw zoom factor, interpolated
    /// between the snapped focal lengths of the device's lens stops. Used for the
    /// telemetry readout so the displayed value tracks pinch zoom smoothly while still
    /// snapping to canonical numbers (13 / 24 / 120 mm etc.) at the lens stops.
    private func focalLength35mm(forZoom zoom: CGFloat) -> Double {
        guard let lenses = camera.device?.lenses else { return 0 }
        let sorted = lenses.sorted { $0.zoomFactor < $1.zoomFactor }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if zoom <= first.zoomFactor { return first.snapping().focalLength35mm }
        if zoom >= last.zoomFactor {
            // Beyond the last physical lens stop, scale the last lens's focal length
            // linearly with extra digital zoom — matches what the sensor effectively
            // sees (focal length × zoom factor).
            let lastSnapped = last.snapping().focalLength35mm
            return lastSnapped * Double(zoom / last.zoomFactor)
        }
        for index in 0 ..< (sorted.count - 1) {
            let low = sorted[index]
            let high = sorted[index + 1]
            if zoom >= low.zoomFactor, zoom <= high.zoomFactor {
                let t = Double((zoom - low.zoomFactor) / (high.zoomFactor - low.zoomFactor))
                let lowFocal = low.snapping().focalLength35mm
                let highFocal = high.snapping().focalLength35mm
                return lowFocal + t * (highFocal - lowFocal)
            }
        }
        return first.snapping().focalLength35mm
    }

    /// Seeds zoom to the lens whose snapped 35mm-equivalent focal length is closest to 24mm.
    /// iPhone wide lenses usually report 24-26mm, so this picks the main camera on every
    /// device that has one and falls back to the closest lens on devices that don't.
    /// Routes through `selectLens` so the matching chip lights up immediately on first
    /// boot (without it, the highlight stays on whichever lens AVFoundation cold-started
    /// at — usually ultrawide / 13mm).
    private func applyDefaultFocalLength() async {
        let target: Double = 24
        guard let lenses = camera.device?.lenses, !lenses.isEmpty else { return }
        let pick = lenses.min { lhs, rhs in
            abs(lhs.snapping().focalLength35mm - target) < abs(rhs.snapping().focalLength35mm - target)
        }
        guard let pick else { return }
        let pills = lensStrip.arrangedSubviews.compactMap { $0 as? LensPill }
        guard let pill = pills.first(where: { abs($0.zoomFactor - pick.zoomFactor) < 0.001 }) else {
            await camera.setZoom(pick.zoomFactor)
            return
        }
        selectLens(button: pill, zoomFactor: pick.zoomFactor)
    }

    // MARK: - Mode picker

    private func populateModeStrip() {
        // Gate against the broader device discovery, not just the active one. On Pro
        // iPhones the virtual `.builtInTripleCamera`'s `formats` caps at 60 fps, but the
        // separately-discoverable `.builtInWideAngleCamera` supports 120/240. Slo-mo
        // entry hops to the wide camera (see `applyModeChange`); exit restores the
        // pre-slo-mo device type.
        let supportsSlowMo = PRMCameraDevice.anyDeviceSupportsSlowMotion(at: .back)
        modePicker.supportsSlowMotion = supportsSlowMo
        if !supportsSlowMo {
            logInfo("Slo-mo variant hidden: no back-facing device reports a ≥120 fps format")
        }
        modePicker.select(primary: .photo, variant: .standard)
        applyModeChange(primary: .photo, variant: .standard)
    }

    /// Translates a picker (primary, variant) selection into the `Mode` enum the rest of the
    /// controller already understands. Burst folds into `.photo` via `burstEnabled`; the
    /// Night variants fold into `.night` via `nightDuration`.
    private func applyModeChange(primary: ModePicker.Primary, variant: ModePicker.Variant) {
        PRMLogger.session.notice(
            "Studio applyModeChange: primary=\(String(describing: primary), privacy: .public), variant=\(String(describing: variant), privacy: .public)"
        )
        // Re-apply variant-disable state — `rebuildVariants` swapped the strip contents
        // when the primary changed, dropping any per-variant disable we set previously.
        syncModePickerAvailability()
        burstEnabled = (primary == .photo && variant == .burst)
        if primary == .night {
            switch variant {
            case .nightAuto: nightDuration = .auto
            case .night1s: nightDuration = .oneSecond
            case .night3s: nightDuration = .threeSeconds
            case .night5s: nightDuration = .fiveSeconds
            default: nightDuration = .auto
            }
        }
        switch primary {
        case .photo:
            switch variant {
            case .live: mode = .live
            case .portrait: mode = .portrait
            // Video / Night variants are not exposed as Photo variants by
            // `ModePicker.variants(for:)`, but the enum is shared so the switch needs
            // to be exhaustive.
            case .standard, .burst, .slowMo, .video24, .video30,
                 .nightAuto, .night1s, .night3s, .night5s:
                mode = .photo
            }
        case .video:
            switch variant {
            case .video24: videoFPS = .fps24
            case .video30: videoFPS = .fps30
            default: break
            }
            let newMode: Mode = variant == .slowMo ? .slowMo : .video
            // If we're already in `.video` and just changing fps, the `mode` didSet
            // won't fire — apply the new fps directly so the picker stays in sync.
            if mode == newMode, newMode == .video {
                Task { await camera.setFrameRate(videoFPS.value) }
            } else {
                mode = newMode
            }
        case .night:
            mode = .night
        }
    }

    private func applyModeChange(from oldMode: Mode) {
        PRMLogger.session.notice(
            "Studio mode change: \(oldMode.label, privacy: .public) → \(self.mode.label, privacy: .public)"
        )
        Task {
            // Live Photo and AVCaptureMovieFileOutput are mutually exclusive on the same
            // session: having both attached forces `isLivePhotoCaptureSupported` to false.
            // Toggle the movie output based on whether the current mode actually needs to
            // record video. Photo / Live / Portrait / Night detach the movie output so
            // Live Photo and Portrait matte work; Video / Slo-Mo re-attach it.
            //
            // **Bake the desired Live Photo state into `setMovieFileOutputAttached`'s
            // own begin/commit via `targetLivePhoto:`** instead of following it with a
            // separate `setLivePhotoCaptureEnabled` call. Two back-to-back toggles
            // (detach's mutual-exclusion side-effect, then the explicit setter) strand
            // the secondary movie pipeline on virtual devices — see PRMCameraSession's
            // `setMovieFileOutputAttached(_:targetLivePhoto:)` doc for the full
            // rationale. Manual sliders / WB lock only behave when the photo output
            // isn't advertising Live Photo (Live Photo's continuous-auto pipeline
            // re-asserts the AE/AWB system), so any non-Live mode needs Live Photo OFF.
            let needsMovieOutput = (mode == .video || mode == .slowMo)
            let needsLivePhoto = (mode == .live)
            do {
                try await camera.setMovieFileOutputAttached(needsMovieOutput, targetLivePhoto: needsLivePhoto)
                await refreshVideoRecorder()
            } catch {
                reportError(error, context: "Mode switch")
            }

            // Pro iPhones expose 120/240 fps slo-mo formats only on the physical wide
            // camera, not on the virtual triple. Hop devices on slo-mo entry / exit so
            // `setFrameRate(120)` actually has a format to lock onto. The triple→wide
            // and wide→triple transitions are the common case; other deviceType pairs
            // (e.g. front camera with no slo-mo at all) are gated upstream by the
            // picker's `supportsSlowMotion` visibility check.
            let enteringSlowMo = oldMode != .slowMo && mode == .slowMo
            let exitingSlowMo = oldMode == .slowMo && mode != .slowMo
            if enteringSlowMo {
                await switchToSlowMoDevice()
            } else if exitingSlowMo {
                await restoreNonSlowMoDevice()
            }

            // Depth-aware portrait needs a format that streams depth — the `.photo`
            // session preset on iPhone Pro models picks a non-depth-streaming format,
            // so without this hop depth ancillaries arrive empty. We enable depth on
            // entering Portrait and leave it on for the rest of the session; see the
            // `enableDepthFormat` doc for why there's no disable counterpart.
            let enteringPortrait = oldMode != .portrait && mode == .portrait
            if enteringPortrait {
                let activated = await camera.enableDepthFormat()
                if !activated {
                    logInfo("Portrait: no depth-capable format on the active device")
                }
                // Rebuild the chip strip after the format swap. `prm_lenses()` reads
                // `activeFormat.secondaryNativeResolutionZoomFactors` and the device's
                // `maxAvailableVideoZoomFactor`, both of which can shift when the depth
                // format restricts the available constituent lenses (e.g. a wide-only
                // depth format on a triple device would clip away the telephoto chip).
                rebuildLensStrip()
            }

            switch mode {
            case .photo, .live, .portrait, .night:
                await camera.resetFrameRate()
                shutter.setMode(.photo)
            case .video:
                await camera.setFrameRate(videoFPS.value)
                shutter.setMode(.recording)
            case .slowMo:
                let target: Float64 = (camera.device?.maxFrameRate ?? 30) >= 240 ? 240 : 120
                await camera.setFrameRate(target)
                shutter.setMode(.recording)
            }

            // Reset zoom on every real mode change. Without this, switching from
            // (e.g.) Photo @ 5× telephoto to Portrait lands on the telephoto lens —
            // the `applyDefaultFocalLength` startup call picks the wide lens via
            // `selectLens`, which pins the 24mm chip highlight, but the actual
            // `videoZoomFactor` stays at 5×, so the chip and the live preview
            // disagree. Slo-mo entry/exit already does this for its own reasons
            // (digital crop compounding the sensor crop); apply the same baseline
            // to the photo-family modes too.
            if oldMode != mode, mode != .slowMo {
                await applyDefaultFocalLength()
            }

            // Seed the AUTO chip label so users see the resolved duration immediately
            // when entering Night — without this it would be blank until the next
            // telemetry tick fires.
            if mode == .night { refreshNightAutoLabel() }
        }
    }

    /// Pre-slo-mo device type, captured so `restoreNonSlowMoDevice` can swap back to
    /// whichever virtual device was active before the user entered slo-mo. `nil` outside
    /// of the slo-mo window — the property's lifetime brackets the entry/exit pair.
    private var preSlowMoDeviceType: AVCaptureDevice.DeviceType?

    private func switchToSlowMoDevice() async {
        let current = camera.device
        guard let current else { return }
        // Skip the hop if the current device already supports 120 fps — the wide camera
        // path is only needed when the active device is a virtual one that doesn't
        // expose the slo-mo formats.
        guard current.maxFrameRate < 120 else { return }
        preSlowMoDeviceType = current.deviceType
        do {
            pipeline.isEnabled = false
            // Detach the photo output BEFORE switching to wide + bumping to 240 fps.
            // Wide camera + photo output (with its Live Photo secondary movie pipeline)
            // + video data output + movie output + 240 fps exceeds the ISP bandwidth
            // budget per WWDC19 session 249 — AVF surfaces `AVError -11872 "Cannot
            // Record — Too many camera hardware resources were requested"` via the
            // runtime-error stream even though recording still proceeds. Apple's own
            // Camera app drops the photo output for slo-mo for exactly this reason
            // (slo-mo never offers Live Photo). The cached `photoCapture` /
            // `nightCapture` wrappers stay valid because they hold the OLD output
            // instance; we rebuild them on slo-mo exit via the existing capture-entry
            // `refreshPhotoCaptureIfOutputChanged()` calls (slo-mo doesn't shoot
            // stills, so no path through them while detached).
            try? await camera.setPhotoOutputAttached(false)
            try await camera.switchDevice(type: .builtInWideAngleCamera, position: current.position)
            // Re-seed the portrait baseline before the rotation coordinator catches up.
            // A fresh device's video-data-output connection comes up at raw sensor
            // orientation (landscape, 0°); without this the preview is sideways for
            // the first ~100ms until the coordinator stream fires.
            await applyConnectionRotation(90)
            // Slo-mo formats are narrower-aspect than the photo format (16:9 vs 4:3) AND
            // use a smaller sensor active area. With the default `.fit` letterbox, the
            // preview shrinks visibly compared to normal video. Switch to `.fill` so the
            // slo-mo frame zooms to match the screen real-estate the user expects —
            // mirroring Apple Camera's behavior of edge-to-edge slo-mo preview.
            previewView.contentFit = .fill
            // Reset zoom to 1.0 so any digital crop the user dialed in on the prior
            // device doesn't compound the high-fps sensor crop.
            await camera.setZoom(1.0)
            pipeline.isEnabled = true
            rebuildLensStrip()
            await rebindRotationCoordinator()
            await applyDefaultFocalLength()
        } catch {
            pipeline.isEnabled = true
            preSlowMoDeviceType = nil
            reportError(error, context: "Enter slo-mo")
        }
    }

    private func restoreNonSlowMoDevice() async {
        guard let priorType = preSlowMoDeviceType else { return }
        preSlowMoDeviceType = nil
        let position = camera.device?.position ?? .back
        do {
            pipeline.isEnabled = false
            try await camera.switchDevice(type: priorType, position: position)
            // Re-attach the photo output that `switchToSlowMoDevice` detached. The
            // new instance is a fresh `AVCapturePhotoOutput`; cached
            // `PRMPhotoCapture` wrappers (photoCapture / nightCapture) will be
            // identity-rebuilt on the next capture call via
            // `refreshPhotoCaptureIfOutputChanged()`.
            try? await camera.setPhotoOutputAttached(true)
            // See `switchToSlowMoDevice` — same baseline re-seed for the rebuilt
            // connection.
            await applyConnectionRotation(90)
            // Restore the letterbox so the photo-format aspect ratio is visible.
            previewView.contentFit = .fit
            pipeline.isEnabled = true
            rebuildLensStrip()
            await rebindRotationCoordinator()
            await applyDefaultFocalLength()
        } catch {
            pipeline.isEnabled = true
            reportError(error, context: "Exit slo-mo")
        }
    }

    // MARK: - Manual-mode device switching

    /// Device type Studio was on before the user first touched a manual slider.
    /// Restored once *both* exposure and WB return to auto, so the lens chip
    /// strip and multi-lens optical zoom come back. `nil` while we're either on
    /// the default virtual device (no switch happened yet) or already committed
    /// to wide for manual.
    private var preManualDeviceType: AVCaptureDevice.DeviceType?

    /// Switch to the physical `.builtInWideAngleCamera` before applying any
    /// manual exposure / WB lock, if we're currently on a virtual multi-camera
    /// device (`.builtInTripleCamera` / `.builtInDualCamera` /
    /// `.builtInDualWideCamera`). Virtual devices compose frames across
    /// multiple constituent physical cameras; per Apple's white-balance docs,
    /// "exposure duration, ISO, aperture, white balance gains, or lens
    /// position may change when the device switches from one camera to the
    /// other," and `isLockingWhiteBalanceWithCustomDeviceGainsSupported` /
    /// `setExposureModeCustom` can be silently rejected on the virtual device
    /// while the constituent auto-AE / auto-AWB systems keep re-asserting.
    /// User-visible symptom on iPhone 15 Pro Max: WB slider drag doesn't
    /// change preview color, ISO / shutter sliders update labels but the
    /// saved photo's EXIF shows continuous-auto values.
    ///
    /// On the wide camera (a physical AVCaptureDevice with no constituents),
    /// `setExposureModeCustom` and `setWhiteBalanceModeLocked` land
    /// immediately and stick. Called from every manual slider's
    /// `.valueChanged` handler — idempotent (no-op when already on wide).
    /// Returns the LV reference for reciprocity math, captured from the on-screen
    /// state BEFORE any device swap. Only meaningful when the device is currently in
    /// continuous-auto exposure (i.e. the user is about to enter manual for the first
    /// time). Returns `nil` in manual mode, where `PRMCamera` should keep using its
    /// own snapshotted baseline.
    private func currentAutoExposureBaseline() -> (iso: Float, durationSeconds: Double)? {
        let state = camera.state
        let isAuto = state.exposureMode == .continuousAutoExposure || state.exposureMode == .autoExpose
        guard isAuto,
              state.iso > 0,
              let duration = state.exposureDurationSeconds,
              duration > 0
        else { return nil }
        return (iso: state.iso, durationSeconds: duration)
    }

    private func ensureWideCameraForManual() async {
        guard let current = camera.device else { return }
        let virtualDeviceTypes: Set<AVCaptureDevice.DeviceType> = [
            .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera,
        ]
        guard virtualDeviceTypes.contains(current.deviceType) else { return }
        preManualDeviceType = current.deviceType
        // Snapshot EV bias on the source device before the swap. Per Apple AVCaptureDevice
        // docs ("exposure duration, ISO, aperture, white balance gains, or lens position
        // may change when the device switches from one camera to the other"), each
        // device has an independent AE engine — the wide camera meters a narrower FOV
        // than the triple's virtual blend and lands at a different baseline LV. Carrying
        // the user's EV offset across the swap preserves their relative exposure intent
        // (e.g. "+0.7 stops brighter than what the camera meters").
        let priorBias = camera.state.exposureBias
        do {
            pipeline.isEnabled = false
            try await camera.switchDevice(
                type: .builtInWideAngleCamera,
                position: current.position
            )
            if abs(priorBias) > 0.01 {
                await camera.setExposureBias(priorBias)
            }
            await applyConnectionRotation(90)
            pipeline.isEnabled = true
            rebuildLensStrip()
            await rebindRotationCoordinator()
        } catch {
            pipeline.isEnabled = true
            preManualDeviceType = nil
            PRMLogger.session.error(
                "Failed to switch to wide for manual mode: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Inverse of `ensureWideCameraForManual`: restore the virtual device we
    /// were on before any manual slider was touched, but only if both exposure
    /// and WB are now back in auto modes. Idempotent.
    private func restoreVirtualCameraIfFullyAuto() async {
        guard let priorType = preManualDeviceType else { return }
        let state = camera.state
        let exposureIsAuto = state.exposureMode == .continuousAutoExposure
            || state.exposureMode == .autoExpose
        let wbIsAuto = state.whiteBalanceMode == .continuousAutoWhiteBalance
            || state.whiteBalanceMode == .autoWhiteBalance
        guard exposureIsAuto, wbIsAuto else { return }
        preManualDeviceType = nil
        let position = camera.device?.position ?? .back
        do {
            pipeline.isEnabled = false
            try await camera.switchDevice(type: priorType, position: position)
            await applyConnectionRotation(90)
            pipeline.isEnabled = true
            rebuildLensStrip()
            await rebindRotationCoordinator()
        } catch {
            pipeline.isEnabled = true
            PRMLogger.session.error(
                "Failed to restore virtual camera from manual: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Updates the AUTO chip's label in the Night variant row to show the resolved
    /// duration (e.g. `AUTO 3s`). Re-evaluated each telemetry tick so the
    /// recommendation tracks light level. No-op outside Night mode.
    private func refreshNightAutoLabel() {
        guard mode == .night else { return }
        let resolved = resolveAutoNightDuration()
        modePicker.setVariantLabel(for: .nightAuto, to: "AUTO \(resolved.label)")
    }

    /// Apple-Camera-style auto pick. Heuristic from current exposure telemetry:
    /// - shutter ≥ 1/15s OR ISO ≥ 80% of max → 5s (very dark)
    /// - shutter ≥ 1/30s OR ISO ≥ 50% of max → 3s (dim)
    /// - otherwise → 1s (mild boost)
    /// Falls back to `.oneSecond` when telemetry is unavailable.
    private func resolveAutoNightDuration() -> NightDuration {
        let state = camera.state
        guard let device = camera.device else { return .oneSecond }
        let isoMax = device.isoRange.upperBound
        let isoRatio = isoMax > 0 ? state.iso / isoMax : 0
        let shutter = state.exposureDurationSeconds ?? 0

        if shutter >= 1.0 / 15.0 || isoRatio >= 0.8 {
            return .fiveSeconds
        }
        if shutter >= 1.0 / 30.0 || isoRatio >= 0.5 {
            return .threeSeconds
        }
        return .oneSecond
    }

    /// Sets `videoRecorder` to nil when the movie output is detached so
    /// `startRecording()` exits cleanly with a toast, or keeps the existing
    /// session-bound recorder when the output is present. The session-based
    /// `PRMVideoRecorder(session:)` resolves the live output at every `start()`,
    /// so we no longer need to recreate the recorder on every output reattach.
    private func refreshVideoRecorder() async {
        let movieOutput = await camera.session.movieFileOutput
        if movieOutput != nil {
            if videoRecorder == nil {
                videoRecorder = PRMVideoRecorder(session: camera.session)
            }
        } else {
            videoRecorder = nil
        }
    }

    // MARK: - Capture (photo)

    private func performShutter() {
        switch mode {
        case .photo:
            if burstEnabled {
                captureBurst()
            } else {
                capturePhoto()
            }
        case .live:
            captureLivePhoto()
        case .portrait:
            capturePortraitPhoto()
        case .video, .slowMo:
            if recordingStartedAt == nil {
                startRecording()
            } else {
                stopRecording()
            }
        case .night:
            captureNight()
        }
    }

    // Photo-settings knobs surfaced in the drawer — feed every PRMPhotoSettings build via makePhotoSettings().
    private var photoCodec: AVVideoCodecType = .hevc
    private var capMaxDimensions: Bool = false
    private var autoRedEyeReductionEnabled: Bool = false

    /// Builds a `PRMPhotoSettings` honoring the drawer knobs so PRMPhotoSettings.codec /
    /// .maxDimensions / .autoRedEyeReduction actually take effect.
    private func makePhotoSettings(
        flash: AVCaptureDevice.FlashMode,
        quality: AVCapturePhotoOutput.QualityPrioritization
    ) -> PRMPhotoSettings {
        var settings = PRMPhotoSettings()
            .flashMode(flash)
            .qualityPrioritization(quality)
            .codec(photoCodec)
            .autoRedEyeReduction(autoRedEyeReductionEnabled)
        if capMaxDimensions, let output = photoCapture?.output {
            settings = settings.maxDimensions(output.maxPhotoDimensions)
        }
        // Inject the user's manual ISO/shutter intent so PRMPhotoCapture can
        // patch the saved photo's EXIF. PRMCamera's snapshot reflects the
        // slider value (intent) rather than the lagging device read — fixes
        // the saved photo showing auto-AE values even when the live preview
        // and labels show the user's manual settings.
        if let snapshot = camera.currentManualExposureSnapshot {
            settings = settings.manualExposureOverride(iso: snapshot.iso, duration: snapshot.duration)
        }
        return settings
    }

    private func capturePhoto() {
        Task {
            await refreshPhotoCaptureIfOutputChanged()
            await MainActor.run { self.capturePhotoOnCurrent() }
        }
    }

    private func capturePhotoOnCurrent() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .quality)

        flashOverlay()
        Task {
            do {
                let photo = try await photoCapture.capturePhoto(
                    settings: settings,
                    willCapture: { [weak self] in
                        Task { @MainActor [weak self] in self?.shutterFlashTick() }
                    }
                )
                await saveToPhotoLibrary(data: photo.data)
            } catch {
                reportError(error, context: "Capture")
            }
        }
    }

    /// Small UI tick driven by `PRMPhotoCapture.capturePhoto(willCapture:)` — fires on
    /// shutter open, before the photo finishes encoding.
    private func shutterFlashTick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func captureBurst() {
        Task {
            await refreshPhotoCaptureIfOutputChanged()
            await MainActor.run { self.captureBurstOnCurrent() }
        }
    }

    private func captureBurstOnCurrent() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .speed)
        flashOverlay()
        Task {
            do {
                let photos = try await photoCapture.captureBurst(count: 5, settings: settings)
                for photo in photos {
                    await saveToPhotoLibrary(data: photo.data, silent: true)
                }
                showToast("Saved \(photos.count) burst photos")
            } catch {
                reportError(error, context: "Burst")
            }
        }
    }

    private func captureLivePhoto() {
        Task {
            await refreshPhotoCaptureIfOutputChanged()
            await MainActor.run { self.captureLivePhotoOnCurrent() }
        }
    }

    /// Refresh `photoCapture` if the session's current `AVCapturePhotoOutput` is a
    /// different instance from the one we cached at boot. Necessary because the
    /// Live-Photo-recovery reconfigure path in `PRMCameraSession.swapInput` tears
    /// down + recreates the photo output to restore `isLivePhotoCaptureSupported`
    /// on virtual devices — if Studio kept using the pre-reconfigure instance, its
    /// `isLivePhotoCaptureSupported` would silently read false (the old output is
    /// no longer in the session) and every Live capture would fail at the gate.
    private func refreshPhotoCaptureIfOutputChanged() async {
        let currentOutput = await camera.session.photoOutput
        guard let currentOutput else { return }
        if photoCapture?.output !== currentOutput {
            let renderContext = renderContext
            let newCapture = PRMPhotoCapture(output: currentOutput)
            await MainActor.run {
                self.photoCapture = newCapture
                self.nightCapture = PRMNightModeCapture(capture: newCapture, context: renderContext)
            }
        }
    }

    private func captureLivePhotoOnCurrent() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: flashSetting.avMode, quality: .quality)
        flashOverlay()
        liveIndicator.setActive(true)
        Task {
            // `defer` keeps the indicator off even if the await throws — without it the
            // pill would stay pulsing across the next capture.
            defer { liveIndicator.setActive(false) }
            do {
                let live = try await photoCapture.captureLivePhoto(settings: settings)
                await saveLivePhoto(live)
            } catch {
                reportError(error, context: "Live capture")
            }
        }
    }

    private func capturePortraitPhoto() {
        Task {
            await refreshPhotoCaptureIfOutputChanged()
            await MainActor.run { self.capturePortraitPhotoOnCurrent() }
        }
    }

    private func capturePortraitPhotoOnCurrent() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: .off, quality: .quality)
        flashOverlay()
        Task {
            do {
                let portrait = try await photoCapture.capturePortraitPhoto(settings: settings)
                // `PRMPhotoCapture.capturePortraitPhoto` forces HEIC + sets
                // `embedsDepthDataInPhoto` + `embedsPortraitEffectsMatteInPhoto` to true,
                // so `portrait.photo.data` (which comes from
                // `AVCapturePhoto.fileDataRepresentation()`) already contains the depth,
                // matte, and Apple maker-note signals Photos.app needs. Save the bytes
                // unchanged — any CIImage / CGImageDestination round-trip would strip the
                // maker-notes and Photos would treat it as a flat still.
                //
                // Skip the aspect crop for the same reason: re-encoding through CIImage
                // drops the aux + maker-notes. Matches Apple Camera, which always saves
                // Portrait at full sensor framing and lets the user crop in Photos.
                if portrait.depthData == nil, portrait.portraitEffectsMatte == nil {
                    showToast("Portrait depth unavailable for this lens — saved standard photo")
                }
                await saveToPhotoLibrary(data: portrait.photo.data, applyAspectCrop: false)
            } catch {
                reportError(error, context: "Portrait")
            }
        }
    }

    private func captureNight() {
        let resolved: NightDuration = nightDuration == .auto ? resolveAutoNightDuration() : nightDuration
        let params = resolved.capture
        let priorExposureMode = camera.state.exposureMode
        let duration = CMTimeMakeWithSeconds(params.perFrame, preferredTimescale: 1_000_000)
        nightIndicator.setActive(true, frame: 0, total: params.frames)
        Task {
            // Restore the prior auto-exposure mode regardless of how the stack ends —
            // throw, cancellation, or success — so the next photo isn't stuck at the long
            // shutter we just installed.
            defer {
                Task { await self.camera.setExposureMode(priorExposureMode) }
            }
            // Rebuild the night capture wrapper if a session reconfigure since boot
            // replaced the photo output instance (e.g. the Live-Photo-recovery path
            // in `swapInput` for the wide→triple hop on the way into night mode).
            // Same gate `captureLivePhotoOnCurrent` uses; without it the cached
            // `nightCapture.capture.output` points at the detached pre-reconfigure
            // instance whose `maxPhotoDimensions` reads (0, 0) and
            // `connection(with: .video)` returns nil — every night capture then
            // fails with "no video connection" even though the session is healthy.
            await refreshPhotoCaptureIfOutputChanged()
            guard let nightCapture = await MainActor.run(body: { self.nightCapture }) else { return }
            await camera.setCustomExposure(duration: duration, iso: params.iso)
            do {
                let photo = try await nightCapture.capture(
                    frameCount: params.frames,
                    perFrameDuration: params.perFrame,
                    iso: params.iso,
                    didCaptureFrame: { [weak self] index, total in
                        Task { @MainActor [weak self] in
                            self?.nightIndicator.setActive(true, frame: index + 1, total: total)
                        }
                    }
                )
                nightIndicator.setActive(false)
                await saveToPhotoLibrary(data: photo.data)
            } catch {
                nightIndicator.setActive(false)
                reportError(error, context: "Night")
            }
        }
    }

    private func flashOverlay() {
        let cover = UIView()
        cover.backgroundColor = .black
        cover.frame = view.bounds
        view.addSubview(cover)
        cover.alpha = 1
        UIView.animate(withDuration: 0.25, animations: {
            cover.alpha = 0
        }, completion: { _ in cover.removeFromSuperview() })
    }

    private func saveToPhotoLibrary(data: Data, silent: Bool = false, applyAspectCrop: Bool = true) async {
        guard await ensurePhotoLibraryAccess() else { return }
        // Portrait skips the CIImage-backed aspect crop because the re-encode strips
        // depth + matte aux dictionaries, which Photos needs to render Portrait.
        let cropped = applyAspectCrop ? croppedToActiveAspect(data: data) : data
        do {
            try await Self.writePhoto(data: cropped)
            if !silent { showToast("Saved to Photos") }
        } catch {
            reportError(error, context: "Save photo")
        }
    }

    private func saveLivePhoto(_ live: PRMLivePhoto) async {
        guard await ensurePhotoLibraryAccess() else { return }
        // Only the still is cropped; the paired movie keeps its native aspect. Apple's
        // Live Photo viewer letterboxes the movie behind the still anyway, so cropping
        // the still alone matches the first-party Camera app's behavior.
        let photoData = croppedToActiveAspect(data: live.photo.data)
        let movieURL = live.movieURL
        do {
            try await Self.writeLivePhoto(photoData: photoData, movieURL: movieURL)
            showToast("Saved Live Photo")
        } catch {
            reportError(error, context: "Save Live Photo")
            PRMTempFile.remove(movieURL)
        }
    }

    /// Crops JPEG/HEIC photo data to the currently-selected aspect ratio mask, in the
    /// orientation the user sees in the preview. Returns the original bytes when the
    /// active ratio is `.unconstrained` (no crop needed) or when decode fails. EXIF/TIFF
    /// metadata is preserved aside from the orientation tag (forced to `1` because the
    /// output pixels are upright after applying the source orientation).
    ///
    /// `CIImage(data:)` ignores EXIF orientation by default, so the prior implementation
    /// cropped against the *sensor*-orientation extent (landscape 4032×3024 on iPhone)
    /// then copied the original orientation tag back. For aspect ratios that match the
    /// sensor (`.ratio4x3` on a 4:3 sensor) the crop was a no-op — the user sees the
    /// preview cropped to 4:3 in portrait but the saved photo looks identical to
    /// `.unconstrained`. Applying orientation first means we crop in the same coordinate
    /// space the user is looking at, so every aspect ratio actually trims pixels.
    private func croppedToActiveAspect(data: Data) -> Data {
        guard aspectMask.aspectRatio != .unconstrained else { return data }
        // `applyOrientationProperty: true` makes `CIImage(data:)` honor the EXIF
        // orientation tag — the resulting `extent` is in display (upright) coordinates,
        // matching what the user composed in the preview.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let cropRect = aspectMask.cropRect(in: source.extent)
        let cropped = source.cropped(to: cropRect)
        // `cropped(to:)` keeps the original extent's origin; translating back to (0,0)
        // makes the JPEG writer produce a tight image instead of a same-size canvas
        // with everything outside the crop set to transparent.
        let translated = cropped.transformed(
            by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        )
        // Preserve EXIF/TIFF but override the orientation tag — our pixels are already
        // upright, so leaving the original (e.g. `6` = rotate 90° CW for portrait) would
        // make Photos rotate them again. Same fix in both the top-level TIFF dict and
        // the EXIF sub-dict, since either can override the other depending on viewer.
        var properties = readImageProperties(from: data)
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return PRMImage.jpegDataPreservingMetadata(
            from: translated,
            sourceExtent: translated.extent,
            originalProperties: properties,
            context: renderContext
        ) ?? data
    }

    private func readImageProperties(from data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return props
    }

    /// PHPhotoLibrary.performChanges runs its closure on `com.apple.PHPhotoLibrary.changes`.
    /// A closure created inside a `@MainActor` method inherits MainActor isolation and
    /// crashes with `_dispatch_assert_queue_fail` under Swift 6 strict concurrency. The
    /// `nonisolated static func` wrapper severs the isolation chain.
    nonisolated static func writePhoto(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
        }
    }

    nonisolated static func writeLivePhoto(photoData: Data, movieURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            let movieOptions = PHAssetResourceCreationOptions()
            movieOptions.shouldMoveFile = true
            request.addResource(with: .photo, data: photoData, options: photoOptions)
            request.addResource(with: .pairedVideo, fileURL: movieURL, options: movieOptions)
        }
    }

    nonisolated static func writeVideo(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: PHAssetResourceCreationOptions())
        }
    }

    private func ensurePhotoLibraryAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if granted != .authorized, granted != .limited {
                showToast("Photo library access denied")
                return false
            }
            return true
        case .denied, .restricted:
            showToast("Photo library access denied")
            return false
        default:
            return true
        }
    }

    // MARK: - Capture (video)

    private func startRecording() {
        guard let videoRecorder else { return }
        Task {
            do {
                try await videoRecorder.start(rotationAngle: 90)
                recordingStartedAt = Date()
                shutter.setMode(.recordingActive)
                startRecordingTimer()
            } catch {
                reportError(error, context: "Record")
            }
        }
    }

    private func stopRecording() {
        guard let videoRecorder else { return }
        Task {
            do {
                let recording = try await videoRecorder.stop()
                stopRecordingTimer()
                shutter.setMode(mode == .photo ? .photo : .recording)
                await saveRecording(recording)
            } catch {
                reportError(error, context: "Stop recording")
                stopRecordingTimer()
            }
        }
    }

    private func saveRecording(_ recording: PRMRecording) async {
        let url = recording.url
        do {
            try await Self.writeVideo(url: url)
            showToast("Saved video")
        } catch {
            reportError(error, context: "Save video")
        }
    }

    private func startRecordingTimer() {
        recordingTimerLabel.isHidden = false
        recordingTimerLabel.text = "● 00:00"
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let started = self.recordingStartedAt else { return }
                let elapsed = Int(Date().timeIntervalSince(started))
                let m = elapsed / 60
                let s = elapsed % 60
                self.recordingTimerLabel.text = String(format: "● %02d:%02d", m, s)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingTimerLabel.isHidden = true
        recordingStartedAt = nil
    }

    // MARK: - Shutter

    private func handleShutterTap() {
        PRMLogger.capture.notice(
            "Studio shutter tap: mode=\(self.mode.label, privacy: .public), timer=\(self.timerSetting.rawValue), maxDim=\(self.capMaxDimensions)"
        )
        guard timerSetting != .off else {
            performShutter()
            return
        }
        startCountdown(from: timerSetting.rawValue) { [weak self] in
            self?.performShutter()
        }
    }

    /// Long-press is meaningful only in video modes (press-and-hold to record). In photo,
    /// live, portrait, night, and pano it is intentionally a no-op so users can't fall into
    /// video recording when they meant to take a photo.
    private func handleShutterLongPressBegan() {
        guard mode == .video || mode == .slowMo else { return }
        if recordingStartedAt == nil {
            startRecording()
        }
    }

    private func handleShutterLongPressEnded() {
        guard mode == .video || mode == .slowMo else { return }
        if recordingStartedAt != nil {
            stopRecording()
        }
    }

    private func startCountdown(from seconds: Int, completion: @escaping () -> Void) {
        countdownLabel.isHidden = false
        countdownLabel.text = "\(seconds)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if remaining == 0 {
                    countdownLabel.isHidden = true
                    completion()
                } else {
                    countdownLabel.text = "\(remaining)"
                }
            }
        }
    }

    private func cycleFlash() {
        flashSetting = flashSetting.next
        flashButton.setSymbol(flashSetting.symbol, active: flashSetting != FlashSetting.off)
    }

    private func cycleGrid() {
        gridIndex = (gridIndex + 1) % gridCycle.count
        if let type = gridCycle[gridIndex] {
            gridOverlay.gridType = type
            gridOverlay.isGridVisible = true
            gridButton.setActive(true)
        } else {
            gridOverlay.isGridVisible = false
            gridButton.setActive(false)
        }
    }

    private func cycleAspect() {
        aspectIndex = (aspectIndex + 1) % aspectCycle.count
        aspectMask.aspectRatio = aspectCycle[aspectIndex]
        let active = aspectMask.aspectRatio != .unconstrained
        aspectButton.setActive(active)
    }

    private func cycleTimer() {
        timerSetting = timerSetting.next
        timerButton.setSymbol(timerSetting.symbol, active: timerSetting != .off)
    }

    private func toggleDrawer() {
        drawer.isUserInteractionEnabled = true
        drawer.setOpen(!drawer.isOpen, animated: true)
        if !drawer.isOpen {
            drawer.isUserInteractionEnabled = false
        }
        drawer.onClose = { [weak self] in
            self?.drawer.isUserInteractionEnabled = false
        }
    }

    // MARK: - Switch camera

    private func flipCamera() async {
        let current = camera.device?.position ?? .back
        let next: AVCaptureDevice.Position = current == .back ? .front : .back
        PRMLogger.session.notice("Studio flipCamera: \(current.rawValue) → \(next.rawValue)")
        do {
            pipeline.isEnabled = false
            try await camera.switchCamera(to: next)
            pipeline.isEnabled = true
            previewView.mirroring = (next == .front)
            rebuildLensStrip()
            populateModeStrip()
            // Swapping the video input recreates the data-output connection, which
            // resets `videoRotationAngle` to 0 (raw sensor landscape). Without a
            // baseline, the preview shows landscape until the new rotation coordinator
            // emits a non-zero angle — which is gated on CoreMotion samples and can lag
            // visibly, especially on the front camera where the user is now staring
            // directly at the sideways preview. Apply 90° immediately so the preview is
            // portrait from frame 1; the coordinator's first emission then refines it as
            // the device tilts. Same angle works for both cameras — AVFoundation
            // absorbs the sensor-orientation difference, and the front-camera mirror is
            // handled separately in `PRMPreviewView.mirroring`.
            await applyConnectionRotation(90)
            await rebindRotationCoordinator()
            await applyDefaultFocalLength()
        } catch {
            reportError(error, context: "Switch camera")
            pipeline.isEnabled = true
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // The gesture is attached to `previewView` so `location(in: previewView)` is the
        // correct origin for device-coord conversion. Showing the indicator in `previewView`
        // (not `view`) means it lands under the user's finger — passing `in: view` while
        // the point is still in `previewView` coords offsets the indicator by the
        // preview's top inset (the chrome above it), which is the visible bug.
        let previewPoint = gesture.location(in: previewView)
        let devicePoint = previewView.texturePoint(fromViewPoint: previewPoint)
        focusIndicator.show(at: previewPoint, in: previewView)
        Task {
            await camera.setFocusAndExposure(
                focusMode: .autoFocus,
                exposureMode: .autoExpose,
                at: devicePoint,
                monitorSubjectAreaChange: true
            )
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            initialPinchZoom = camera.state.zoomFactor
        case .changed:
            // Map pinch.scale exponentially so the gesture feels uniform across the zoom
            // range. Zoom is logarithmic in perceived FOV change — a 1.0→1.2× scale near
            // 1× looks tiny, while the same 0.2 step near 5× is huge. The 1.5 exponent
            // matches Apple Camera's gesture curve: slow pinches near 1× resolve fine
            // 0.05× steps, fast pinches still hit 10× without effort. `gesture.scale`
            // is ≥ 0 by definition.
            let curved = pow(gesture.scale, 1.5)
            pendingZoomTarget = initialPinchZoom * curved
            startZoomDrainIfNeeded()
        case .ended, .cancelled, .failed:
            // Drain finishes naturally on the next iteration after pendingZoomTarget is
            // consumed. No cancellation needed — the latest target is the right final
            // value.
            break
        default: break
        }
    }

    /// Spawns the drain loop on demand. The loop consumes `pendingZoomTarget`, applies
    /// it via `camera.setZoom`, then checks again — if a newer target arrived while the
    /// actor hop was in flight, the next iteration picks up the latest value and skips
    /// the stale ones. Exits when there's no pending target.
    ///
    /// The drain body is `@MainActor`-isolated so reading `pendingZoomTarget` and
    /// clearing `zoomDrainTask` happen as ordinary MainActor sync work — no extra
    /// `await MainActor.run` hops, no cleanup-race window where the gate is closed but
    /// the task is about to exit. The only suspension point is `camera.setZoom`, which
    /// hops to `@PRMCameraActor` and back.
    private func startZoomDrainIfNeeded() {
        guard zoomDrainTask == nil else { return }
        zoomDrainTask = Task { @MainActor [weak self] in
            while let self, let target = self.pendingZoomTarget {
                self.pendingZoomTarget = nil
                await self.camera.setZoom(target)
            }
            self?.zoomDrainTask = nil
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let translation = gesture.translation(in: view).y / max(view.bounds.height / 2, 1)
        let bias = Float(-translation * 2)
        Task { await camera.setExposureBias(bias) }
    }

    // MARK: - Drawer rows

    private func populateDrawer() {
        guard let device = camera.device else { return }
        lastDevice = device
        drawer.clear()
        drawer.appendSection(title: "Exposure", rows: [
            makeEVRow(device: device),
            makeExposureModeRow(),
            makeISORow(device: device),
            makeShutterRow(device: device),
            makeCustomExposurePresetRow(device: device),
        ])
        drawer.appendSection(title: "White Balance", rows: [
            makeWhiteBalanceModeRow(),
            makeWhiteBalanceRow(),
        ])
        drawer.appendSection(title: "Focus", rows: [
            makeFocusModeRow(),
            makeFocusRow(),
        ])
        drawer.appendSection(title: "Zoom", rows: [
            makeZoomRampRow(device: device),
        ])
        drawer.appendSection(title: "Capture", rows: [
            makeHDRRow(),
            makeLowLightRow(),
            makeStabilizationRow(),
        ])
        drawer.appendSection(title: "Format", rows: [
            makeCodecRow(),
            makeMaxDimensionsRow(),
            makeRedEyeRow(),
        ])

        // Wire the disabled-state toast handler on every row that can flip into the
        // disabled state. The handler itself is stable across the row's lifetime; only
        // the `disabledMessage` changes per state-stream tick.
        let toast: (String) -> Void = { [weak self] message in self?.showToast(message) }
        evRow?.onDisabledTap = toast
        isoRow?.onDisabledTap = toast
        shutterRow?.onDisabledTap = toast
        wbRow?.onDisabledTap = toast
        focusRow?.onDisabledTap = toast
        maxDimensionsRow?.onDisabledTap = toast
        syncMaxDimensionsRow()
        syncModePickerAvailability()
    }
}

// MARK: - Drawer row builders

extension StudioViewController {
    private func makeExposureModeRow() -> PRMSettingsRow {
        // 4-segment: Locked / Auto / Cont / Custom. The Custom segment is read-only —
        // tapping it shows the user a toast pointing them to the ISO / Shutter sliders
        // (or the Custom Exposure preset row) since `.custom` only takes effect via a
        // duration+iso pair, not a bare mode set. The segmented control reflects the
        // active mode from the state stream so dragging ISO / Shutter (which promotes
        // to `.custom` under the hood) keeps this UI truthful.
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont", "Custom"])
        segmented.selectedSegmentIndex = 1
        let row = PRMSettingsRow(
            symbolName: "lock.shield",
            title: "Exposure Mode",
            valueText: "auto",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            switch segmented.selectedSegmentIndex {
            case 0:
                row?.valueText = "locked"
                Task { await self.camera.setExposureMode(.locked) }
            case 1:
                row?.valueText = "auto"
                Task {
                    await self.camera.setExposureMode(.autoExpose)
                    await self.restoreVirtualCameraIfFullyAuto()
                }
            case 2:
                row?.valueText = "continuous"
                Task {
                    await self.camera.setExposureMode(.continuousAutoExposure)
                    await self.restoreVirtualCameraIfFullyAuto()
                }
            case 3:
                // `.custom` requires a (duration, iso) pair. Don't apply it from a bare
                // segment tap — the API call would no-op. Roll the segmented back to the
                // current mode and prompt the user toward the sliders.
                showToast("Drag ISO or Shutter to enter Custom")
                applyExposureModeUI(self.camera.state.exposureMode, to: segmented, row: row)
            default: break
            }
        }, for: .valueChanged)
        exposureModeSegmented = segmented
        return row
    }

    private func makeCustomExposurePresetRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Day", "Indoor", "Night"])
        segmented.selectedSegmentIndex = UISegmentedControl.noSegment
        let row = PRMSettingsRow(
            symbolName: "wand.and.stars",
            title: "Custom Exposure",
            valueText: "—",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let (duration, iso, label): (CMTime, Float, String) = switch segmented.selectedSegmentIndex {
            case 0:
                (CMTime(value: 1, timescale: 500), max(50, device.isoRange.lowerBound), "1/500 · ISO \(Int(max(50, device.isoRange.lowerBound)))")
            case 1:
                (CMTime(value: 1, timescale: 60), min(400, device.isoRange.upperBound), "1/60 · ISO \(Int(min(400, device.isoRange.upperBound)))")
            default:
                (CMTime(value: 1, timescale: 30), min(1600, device.isoRange.upperBound), "1/30 · ISO \(Int(min(1600, device.isoRange.upperBound)))")
            }
            row?.valueText = label
            // Reflect the preset into the ISO + Shutter sliders so the user can see and
            // continue dragging from the preset's values. Mode follows on the next state
            // tick (`setCustomExposure` promotes to `.custom`).
            syncManualExposureControls(durationSeconds: CMTimeGetSeconds(duration), iso: iso)
            Task { await camera.setCustomExposure(duration: duration, iso: iso) }
        }, for: .valueChanged)
        customExposureSegmented = segmented
        return row
    }

    private func makeWhiteBalanceModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont"])
        segmented.selectedSegmentIndex = 1
        let row = PRMSettingsRow(
            symbolName: "circle.dashed",
            title: "WB Mode",
            valueText: "auto",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let mode: AVCaptureDevice.WhiteBalanceMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .locked; row?.valueText = "locked"
            case 1: mode = .autoWhiteBalance; row?.valueText = "auto"
            default: mode = .continuousAutoWhiteBalance; row?.valueText = "continuous"
            }
            Task {
                await self.camera.setWhiteBalanceMode(mode)
                await self.restoreVirtualCameraIfFullyAuto()
            }
        }, for: .valueChanged)
        wbModeSegmented = segmented
        return row
    }

    private func makeFocusModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont"])
        segmented.selectedSegmentIndex = 2
        let row = PRMSettingsRow(
            symbolName: "scope",
            title: "Focus Mode",
            valueText: "continuous",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let mode: AVCaptureDevice.FocusMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .locked; row?.valueText = "locked"
            case 1: mode = .autoFocus; row?.valueText = "auto"
            default: mode = .continuousAutoFocus; row?.valueText = "continuous"
            }
            let session = camera.session
            Task { @PRMCameraActor in
                guard let device = session.videoDevice else { return }
                try? device.prm_setFocusMode(mode)
            }
            Task { @MainActor [weak self] in
                // Bare focus-mode set doesn't go through `PRMCamera`, so refresh state
                // manually to drive `updateTelemetry` and the downstream UI sync.
                await self?.camera.refreshState()
            }
        }, for: .valueChanged)
        focusModeSegmented = segmented
        return row
    }

    private func makeZoomRampRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let button = UIButton(type: .system)
        button.setTitle("Ramp", for: .normal)
        button.setTitleColor(.systemYellow, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        // Label the ramp targets with the actual 35mm-equivalent focal lengths users
        // already read in the telemetry strip, instead of raw zoom factors. On a
        // triple-camera iPhone "1× ↔ 2×" is "24mm ↔ 48mm" (wide → wide sensor crop),
        // matching what users say when they zoom Apple Camera.
        let idleLabel = "\(Int(focalLength35mm(forZoom: 1.0).rounded()))mm ↔ \(Int(focalLength35mm(forZoom: 2.0).rounded()))mm"
        let row = PRMSettingsRow(
            symbolName: "arrow.up.right.and.arrow.down.left.rectangle",
            title: "Smooth Ramp",
            // Pick a meaningful target each tap: ping-pong between the wide lens at 1×
            // and 2×. Hardcoding `2×` (the previous behavior) was a no-op whenever the
            // user had already pinched to 2× and tapped Ramp — same source and target,
            // AVFoundation returned immediately, the user saw the button flip to
            // "Cancel" but no zoom motion.
            valueText: idleLabel,
            content: button
        )
        button.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            if isZoomRamping {
                Task { await self.camera.cancelZoomRamp() }
                isZoomRamping = false
                row?.valueText = idleLabel
                button.setTitle("Ramp", for: .normal)
                return
            }
            // Pick the target that's furthest from the current zoom so the ramp is
            // always visible. Clamp to the device's range — on iPhones with no 2×
            // available (e.g. the front camera maxes at ~1× on most models), fall back
            // to half the max range.
            let current = camera.state.zoomFactor
            let candidate: CGFloat = (current < 1.5) ? 2.0 : 1.0
            let target = min(max(candidate, device.minZoomFactor), device.maxZoomFactor)
            guard abs(target - current) > 0.05 else {
                showToast("Already at \(Int(focalLength35mm(forZoom: target).rounded()))mm")
                return
            }
            isZoomRamping = true
            row?.valueText = "ramping → \(Int(focalLength35mm(forZoom: target).rounded()))mm…"
            button.setTitle("Cancel", for: .normal)
            // Kick off the ramp and a watcher that flips the UI back to idle once
            // AVFoundation reports the ramp finished. Rate 1.0 = `pow(2, t)` factor
            // per second; the watcher polls at 100 ms which is well below human-visible
            // ramp completion lag (~1 s for a 1× → 2× ramp).
            Task { [weak self, weak row, weak button] in
                guard let self else { return }
                await camera.rampZoom(to: target, rate: 1.0)
                // Poll at ~30Hz during the ramp so `refreshState`'s state-stream tick
                // pulls the live `videoZoomFactor` smoothly into telemetry — without
                // this, the focal-length readout only resamples every 500ms (the idle
                // telemetry tick) so the user sees the focal length jump from one
                // discrete sample to the next, then a final big jump as the ramp lands.
                // 30Hz feels continuous and is well under the actor-hop overhead.
                while !Task.isCancelled, await self.isDeviceRamping() {
                    await self.camera.refreshState()
                    try? await Task.sleep(for: .milliseconds(33))
                }
                // Final pull after AVFoundation reports the ramp finished, so the
                // telemetry settles on the exact landed `videoZoomFactor` (the last
                // 30Hz pull during the loop captured an in-flight value, not the
                // committed end value).
                await self.camera.refreshState()
                isZoomRamping = false
                row?.valueText = idleLabel
                button?.setTitle("Ramp", for: .normal)
            }
        }, for: .touchUpInside)
        return row
    }

    /// Reads `device.isRampingVideoZoom` on the camera actor — used by the Ramp row to
    /// auto-flip its button back to "Ramp" when AVFoundation reports the smooth ramp
    /// has completed.
    private func isDeviceRamping() async -> Bool {
        let session = camera.session
        return await PRMCameraActor.shared.run {
            await session.videoDevice?.isRampingVideoZoom ?? false
        }
    }

    private func makeMaxDimensionsRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = capMaxDimensions
        let row = PRMSettingsRow(
            symbolName: "square.dashed",
            title: "Max Dimensions",
            valueText: toggle.isOn ? "cap" : "default",
            content: toggle
        )
        toggle.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            capMaxDimensions = toggle.isOn
            row?.valueText = toggle.isOn ? "cap" : "default"
            // Switch the device's `activeFormat` per toggle state. On (48MP-capable
            // format) is incompatible with Live Photo / burst / depth — see
            // `syncModePickerAvailability` for the mode-picker gating that follows.
            //
            // Critical: 48MP capture is **only exposed on the physical wide camera**.
            // Virtual devices (`.builtInTripleCamera` etc.) cap at the device's
            // largest virtual-fusion-compatible format — on iPhone 15 Pro Max that's
            // 24MP (5712×4284), NOT the 48MP entry that's available on the wide
            // constituent. Without an explicit swap, toggling Max Dimensions on
            // 15 Pro Max picks 24MP and the user sees no benefit. Force a hop to
            // wide first; on toggle-off, restore the virtual device.
            let modeBefore = mode
            PRMLogger.session.notice(
                "Studio Max Dimensions toggle → \(toggle.isOn ? "on" : "off", privacy: .public) (mode=\(modeBefore.label, privacy: .public))"
            )
            Task {
                if toggle.isOn {
                    await self.ensureWideCameraForManual()
                }
                await self.camera.setHighResolutionPhotoFormat(toggle.isOn)
                if !toggle.isOn {
                    await self.restoreVirtualCameraIfFullyAuto()
                }
                await MainActor.run {
                    self.syncModePickerAvailability()
                    // Max ON disables Live / Burst / Portrait at the session level. If the
                    // user was already in one of those modes when they toggle Max on, the
                    // picker chip becomes disabled but `self.mode` still points at it —
                    // and `applyModeChange` is the only path that updates the photo
                    // output's Live Photo state (via `setMovieFileOutputAttached(_:
                    // targetLivePhoto: mode == .live)`). Without dropping the mode back
                    // to `.photo` here, a subsequent capture fails with `Live Photo is
                    // not enabled on the photo output` even though the user's last chip
                    // tap selected Live. The system Camera app handles the same cross-
                    // feature conflict by silently moving the mode picker.
                    if toggle.isOn, self.mode == .live || self.mode == .portrait {
                        PRMLogger.session.notice(
                            "Studio: Max ON forces mode \(self.mode.label, privacy: .public) → photo (incompatible with Max Dimensions)"
                        )
                        self.modePicker.select(primary: .photo, variant: .standard)
                        self.applyModeChange(primary: .photo, variant: .standard)
                    }
                }
            }
        }, for: .valueChanged)
        maxDimensionsRow = row
        maxDimensionsToggle = toggle
        return row
    }

    /// Flips the Max Dimensions row's disabled state based on whether the active
    /// device can actually deliver >12MP photos. Virtual devices (`triple`, `dual`,
    /// `dualWide`) cap at 12MP regardless of format selection — only the physical
    /// `.builtInWideAngleCamera` exposes the 48MP entry on iPhone 14 Pro+. When
    /// disabled, the toggle is force-off (so a capture doesn't request a maxDimensions
    /// the device can't honor) and a tap surfaces a toast explaining the limitation.
    /// Called from every state-stream tick and after `ensureWideCameraForManual`.
    private func syncMaxDimensionsRow() {
        guard let row = maxDimensionsRow, let toggle = maxDimensionsToggle else { return }
        let supported = currentDeviceSupportsHighResPhoto()
        if supported {
            row.setDisabled(message: nil)
            toggle.isEnabled = true
        } else {
            row.setDisabled(message: "Current lens caps at 12MP. Switch to wide for higher resolution.")
            toggle.isEnabled = false
            if toggle.isOn {
                toggle.isOn = false
                capMaxDimensions = false
                row.valueText = "default"
            }
        }
    }

    /// Whether high-resolution (> 12MP) photo capture is reachable from the user's
    /// position. The toggle hops to `.builtInWideAngleCamera` when needed (see the
    /// Max Dimensions row action), so this returns `true` whenever EITHER the
    /// active device OR the wide camera at the current position can deliver > 12MP.
    /// Without the "or wide camera" branch the toggle was disabled on iPhone 15 Pro
    /// Max in virtual-triple mode even though hopping to wide would have unlocked
    /// the 48MP format.
    private func currentDeviceSupportsHighResPhoto() -> Bool {
        let twelveMP = Int64(4032) * Int64(3024)
        if let dims = camera.device?.maxSupportedPhotoDimensions,
           Int64(dims.width) * Int64(dims.height) > twelveMP {
            return true
        }
        // Active device caps at 12MP (e.g. virtual triple on iPhone 15 Pro Max
        // exposes 24MP via constituent fusion, but the 48MP entry is only on the
        // physical wide). Check whether the wide camera at the current position
        // could deliver >12MP after a device hop.
        let position = camera.device?.position ?? .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        for device in discovery.devices {
            for format in device.formats {
                for dim in format.supportedMaxPhotoDimensions where dim.width >= dim.height {
                    if Int64(dim.width) * Int64(dim.height) > twelveMP {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Greys out variant pills that are incompatible with the current configuration.
    /// Today the only cross-feature exclusion is Max Dimensions ↔ Live Photo / Burst /
    /// Portrait: the 48MP photo format doesn't stream the parallel movie pipeline those
    /// modes need. Tapping a disabled pill surfaces a toast instead of switching modes.
    private func syncModePickerAvailability() {
        let blockedByMax = capMaxDimensions ? "Turn off Max Dimensions to use this mode." : nil
        modePicker.setVariantDisabled(.live, message: blockedByMax)
        modePicker.setVariantDisabled(.burst, message: blockedByMax)
        modePicker.setVariantDisabled(.portrait, message: blockedByMax)
    }

    private func makeRedEyeRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = autoRedEyeReductionEnabled
        let row = PRMSettingsRow(
            symbolName: "eye.trianglebadge.exclamationmark",
            title: "Auto Red-Eye",
            valueText: toggle.isOn ? "on" : "off",
            content: toggle
        )
        toggle.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            autoRedEyeReductionEnabled = toggle.isOn
            row?.valueText = toggle.isOn ? "on" : "off"
        }, for: .valueChanged)
        return row
    }

    private func makeEVRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = device.exposureBiasRange.lowerBound
        slider.maximumValue = device.exposureBiasRange.upperBound
        slider.value = camera.state.exposureBias
        let row = PRMSettingsRow(
            symbolName: "plusminus",
            title: "EV",
            valueText: String(format: "%+0.1f", camera.state.exposureBias),
            content: slider
        )
        slider.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let bias = slider.value
            row?.valueText = String(format: "%+0.1f", bias)
            Task { await self.camera.setExposureBias(bias) }
        }, for: .valueChanged)
        evRow = row
        evSlider = slider
        return row
    }

    private func makeISORow(device: PRMCameraDevice) -> PRMSettingsRow {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center

        let autoChip = TextChip(title: "AUTO")
        let slider = UISlider()
        slider.minimumValue = device.isoRange.lowerBound
        slider.maximumValue = device.isoRange.upperBound
        slider.value = camera.state.iso
        stack.addArrangedSubview(autoChip)
        stack.addArrangedSubview(slider)
        autoChip.snp.makeConstraints { $0.width.equalTo(54) }

        let row = PRMSettingsRow(
            symbolName: "camera.aperture",
            title: "ISO",
            valueText: "auto",
            content: stack
        )
        autoChip.onTap = { [weak self, weak row] in
            guard let self else { return }
            row?.valueText = "auto"
            Task {
                await self.camera.setExposureMode(.continuousAutoExposure)
                await self.restoreVirtualCameraIfFullyAuto()
            }
        }
        // On touchDown, if still in auto mode, snap the slider to the live `state.iso`
        // before the user starts dragging. The slider doesn't auto-track auto-mode
        // telemetry (by design, see `syncDrawerControls`), so without this snap the
        // first drag would land on whatever stale value the slider was constructed
        // with (typically the cold-start ISO before auto-AE converged). Snapping on
        // touchDown means the first drag continues smoothly from the on-screen value.
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let state = camera.state
            let isAuto = state.exposureMode == .continuousAutoExposure || state.exposureMode == .autoExpose
            guard isAuto, state.iso > 0 else { return }
            slider.value = state.iso
        }, for: .touchDown)
        slider.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let iso = slider.value
            row?.valueText = "\(Int(iso))"
            // `PRMCamera.setISO` calls `prm_setCustomExposure` which switches mode to
            // `.custom`. The next state-stream tick reflects that into the Exposure Mode
            // segmented (Custom segment). Also reset the Custom Exposure preset to "—"
            // since the user is now driving a free-form value, not one of the presets.
            customExposureSegmented?.selectedSegmentIndex = UISegmentedControl.noSegment
            // Snapshot the on-screen auto-exposure baseline BEFORE swapping to the wide
            // camera. `ensureWideCameraForManual` wipes `PRMCamera`'s baseline and lets the
            // wide camera's auto-AE re-snapshot a different LV (narrower FOV / different
            // metering), so the post-switch reciprocity math would compute against the
            // wrong reference. Passing the pre-switch baseline pins LV to what the user saw.
            let baseline = currentAutoExposureBaseline()
            Task {
                await self.ensureWideCameraForManual()
                await self.camera.setISO(iso, baseline: baseline)
            }
        }, for: .valueChanged)
        isoRow = row
        isoSlider = slider
        return row
    }

    private func makeShutterRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0.5
        // Build the stop list from the active format's actual range, not a fixed array.
        // The default `.photo` preset typically tops out around 1/3s — leaving the
        // hardcoded 0.5s and 1.0s stops silently clamped, which made the slider feel
        // dead at the long-exposure end. `device.shutterRange` is the live source of truth.
        shutterStops = Self.shutterStops(in: device.shutterRange)
        let row = PRMSettingsRow(
            symbolName: "stopwatch",
            title: "Shutter",
            valueText: "auto",
            content: slider
        )
        // Same on-touchDown snap as the ISO slider — see comment there for the rationale.
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let state = camera.state
            let isAuto = state.exposureMode == .continuousAutoExposure || state.exposureMode == .autoExpose
            guard isAuto, !shutterStops.isEmpty, let durationSec = state.exposureDurationSeconds, durationSec > 0 else { return }
            let index = Self.nearestStopIndex(to: durationSec, in: shutterStops)
            let denom = max(shutterStops.count - 1, 1)
            slider.value = Float(Double(index) / Double(denom))
        }, for: .touchDown)
        slider.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate, !shutterStops.isEmpty else { return }
            let normalized = slider.value
            let index = max(0, min(shutterStops.count - 1, Int(round(Double(normalized) * Double(shutterStops.count - 1)))))
            let seconds = shutterStops[index]
            row?.valueText = Self.formatShutter(seconds)
            customExposureSegmented?.selectedSegmentIndex = UISegmentedControl.noSegment
            // Same baseline-pinning rationale as the ISO slider — see comment there.
            let baseline = currentAutoExposureBaseline()
            Task {
                await self.ensureWideCameraForManual()
                await self.camera.setShutterSpeed(seconds: seconds, baseline: baseline)
            }
        }, for: .valueChanged)
        shutterRow = row
        shutterSlider = slider
        return row
    }

    /// Builds the user-facing shutter-speed stops clamped to the device's supported range.
    /// Mirrors Apple Camera's stop pattern (`1/8000` → `1s`) but skips any stop outside
    /// `[minExposureDuration, maxExposureDuration]` so the slider can't land on a value
    /// the device will silently clamp out from under us.
    private static func shutterStops(in range: ClosedRange<Double>) -> [Double] {
        let candidates: [Double] = [
            1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
            1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1.0, 2.0,
        ]
        return candidates.filter { range.contains($0) }
    }

    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "n/a" }
        return seconds >= 1.0
            ? String(format: "%.1fs", seconds)
            : "1/\(Int(round(1.0 / seconds)))s"
    }

    private func makeWhiteBalanceRow() -> PRMSettingsRow {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        let kelvinSlider = UISlider()
        kelvinSlider.minimumValue = 2500
        kelvinSlider.maximumValue = 8000
        kelvinSlider.value = camera.state.whiteBalanceTemperature
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 6
        chips.distribution = .fillEqually
        let presets: [(label: String, preset: AVCaptureDevice.PRMWhiteBalancePreset)] = [
            ("Tungsten", .tungsten),
            ("Daylight", .daylight),
            ("Cloudy", .cloudy),
            ("Shade", .shade),
        ]
        let row = PRMSettingsRow(
            symbolName: "thermometer.sun",
            title: "WB",
            valueText: "\(Int(camera.state.whiteBalanceTemperature))K",
            content: stack
        )
        for entry in presets {
            let chip = TextChip(title: entry.label)
            chip.onTap = { [weak self, weak row] in
                guard let self else { return }
                row?.valueText = "\(Int(entry.preset.temperature))K"
                isApplyingExternalUpdate = true
                kelvinSlider.value = entry.preset.temperature
                isApplyingExternalUpdate = false
                // `lockWhiteBalance` flips the device into `.locked` mode under the hood —
                // the next state-stream tick will sync the WB Mode segmented to "Locked".
                Task {
                    await self.ensureWideCameraForManual()
                    await self.camera.lockWhiteBalance(preset: entry.preset)
                }
            }
            chips.addArrangedSubview(chip)
        }
        kelvinSlider.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let kelvin = kelvinSlider.value
            row?.valueText = "\(Int(kelvin))K"
            let values = AVCaptureDevice.PRMTemperatureAndTint(temperature: kelvin, tint: 0)
            Task {
                await self.ensureWideCameraForManual()
                await self.camera.lockWhiteBalance(values)
            }
        }, for: .valueChanged)
        stack.addArrangedSubview(kelvinSlider)
        stack.addArrangedSubview(chips)
        wbRow = row
        wbKelvinSlider = kelvinSlider
        return row
    }

    private func makeFocusRow() -> PRMSettingsRow {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = camera.state.lensPosition
        let label = UILabel()
        label.textColor = UIColor.white.withAlphaComponent(0.6)
        label.font = .systemFont(ofSize: 11)
        label.text = "Drag to lock focus distance"
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(label)
        let row = PRMSettingsRow(
            symbolName: "scope",
            title: "Focus",
            valueText: String(format: "%.2f", camera.state.lensPosition),
            content: stack
        )
        slider.addAction(UIAction { [weak self, weak row] _ in
            guard let self, !isApplyingExternalUpdate else { return }
            let pos = slider.value
            row?.valueText = String(format: "%.2f", pos)
            // `setLensPosition` switches the device into `.locked` focus mode — the
            // next state-stream tick will sync the Focus Mode segmented to "Locked".
            // Virtual devices (`.builtInTripleCamera` etc.) report
            // `isFocusModeSupported(.locked) == true` but throw on
            // `setFocusModeLocked(lensPosition:)` — only the physical wide camera
            // honors custom lens position. Swap first.
            Task {
                await self.ensureWideCameraForManual()
                await self.camera.setLensPosition(pos)
            }
        }, for: .valueChanged)
        focusRow = row
        lensSlider = slider
        return row
    }

    private func makeHDRRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Auto", "On", "Off"])
        segmented.selectedSegmentIndex = 0
        let row = PRMSettingsRow(
            symbolName: "circle.lefthalf.filled",
            title: "HDR",
            valueText: "auto",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            switch segmented.selectedSegmentIndex {
            case 0:
                row?.valueText = "auto"
                Task { await self?.camera.setVideoHDR(nil) }
            case 1:
                row?.valueText = "on"
                Task { await self?.camera.setVideoHDR(true) }
            default:
                row?.valueText = "off"
                Task { await self?.camera.setVideoHDR(false) }
            }
        }, for: .valueChanged)
        return row
    }

    private func makeLowLightRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        let row = PRMSettingsRow(
            symbolName: "moon.stars",
            title: "Low-Light Boost",
            valueText: "off",
            content: toggle
        )
        toggle.addAction(UIAction { [weak self, weak row] _ in
            let on = toggle.isOn
            row?.valueText = on ? "on" : "off"
            Task { await self?.camera.setLowLightBoost(on) }
        }, for: .valueChanged)
        return row
    }

    private func makeStabilizationRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Off", "Std", "Cinematic", "Auto"])
        segmented.selectedSegmentIndex = 3
        let row = PRMSettingsRow(
            symbolName: "hand.raised",
            title: "Stabilization",
            valueText: "auto",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            let mode: AVCaptureVideoStabilizationMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .off; row?.valueText = "off"
            case 1: mode = .standard; row?.valueText = "standard"
            case 2: mode = .cinematic; row?.valueText = "cinematic"
            default: mode = .auto; row?.valueText = "auto"
            }
            Task { await self?.camera.setStabilization(mode) }
        }, for: .valueChanged)
        return row
    }

    private func makeCodecRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["JPEG", "HEIC"])
        segmented.selectedSegmentIndex = photoCodec == .jpeg ? 0 : 1
        let row = PRMSettingsRow(
            symbolName: "doc.zipper",
            title: "Codec",
            valueText: photoCodec == .jpeg ? "jpeg" : "heic",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            let codec: AVVideoCodecType = segmented.selectedSegmentIndex == 0 ? .jpeg : .hevc
            photoCodec = codec
            row?.valueText = codec == .jpeg ? "jpeg" : "heic"
        }, for: .valueChanged)
        return row
    }

    // MARK: - Telemetry

    private func updateTelemetry(from state: PRMCameraState) {
        let zoom = "\(Int(focalLength35mm(forZoom: state.zoomFactor).rounded()))mm"
        let iso = "ISO \(Int(state.iso))"
        let shutter = state.exposureDurationSeconds.map(Self.formatShutter) ?? "auto"
        let ev = String(format: "EV %+0.1f", state.exposureBias)
        let temp = "\(Int(state.whiteBalanceTemperature))K"
        let fps = state.frameRate.map { "\(Int($0))fps" } ?? ""
        let modeLabel = mode.label
        telemetryLabel.text = [modeLabel, zoom, iso, shutter, ev, temp, fps]
            .filter { !$0.isEmpty }
            .joined(separator: "  ")

        refreshActiveLens(from: state)

        // Auto-recommend updates as light changes — only does work in Night mode.
        if mode == .night, nightDuration == .auto {
            refreshNightAutoLabel()
        }

        // Keep the drawer's widgets in sync with the camera's actual state and apply
        // the compatibility / disable rules.
        syncDrawerControls(from: state)
    }

    // MARK: - Drawer control sync

    //
    // AVFoundation's auto modes mutate ISO / shutter / WB temperature / lens position
    // every frame without going through a setter; the drawer widgets must mirror that
    // (so the value the user sees matches the value the device is actually using). The
    // sliders / segmented controls used to drift out of sync because the row builders
    // captured initial values but never observed the state stream.

    /// Apply the camera's current state to every drawer widget.
    ///
    /// **Sliders only sync from state when their corresponding mode is the manual mode**
    /// (ISO/Shutter → `.custom` exposure, Kelvin → `.locked` WB, Lens → `.locked` focus).
    /// Under auto modes AVFoundation continuously mutates `state.iso` / `state.whiteBalanceTemperature` /
    /// `state.lensPosition` to track the scene — overwriting the slider with those values
    /// every 500ms made the slider "drift" away from where the user had dragged it. Worse,
    /// it also made first-drag look like a no-op: the user releases at 800, the next 2 Hz
    /// tick fires before AVFoundation has fully promoted to `.custom` (or before
    /// `refreshState()` returns), and the slider snaps back to the auto-driven value just
    /// as the camera was settling. By only syncing when explicitly in the manual mode, the
    /// slider's drag stays sticky until the camera has actually adopted the manual value.
    ///
    /// The value-label text still mirrors live `state.iso` etc. (with an "(auto)" suffix
    /// when in auto modes) so the user can see what AVFoundation is currently using even
    /// when the slider is parked.
    private func syncDrawerControls(from state: PRMCameraState) {
        syncMaxDimensionsRow()
        if let segmented = exposureModeSegmented {
            applyExposureModeUI(state.exposureMode, to: segmented, row: nil)
        }
        if let evSlider, !evSlider.isTracking {
            evSlider.value = state.exposureBias
        }
        evRow?.valueText = String(format: "%+0.1f", state.exposureBias)

        // ISO + Shutter sliders: only follow `state` while in `.custom` exposure.
        if state.exposureMode == .custom,
           let isoSlider, !isoSlider.isTracking {
            isoSlider.value = state.iso
        }
        isoRow?.valueText = (state.exposureMode == .custom)
            ? "\(Int(state.iso))"
            : "\(Int(state.iso)) (auto)"

        if state.exposureMode == .custom,
           let shutterSlider, !shutterSlider.isTracking,
           !shutterStops.isEmpty,
           let durationSec = state.exposureDurationSeconds {
            let index = Self.nearestStopIndex(to: durationSec, in: shutterStops)
            let denom = max(shutterStops.count - 1, 1)
            shutterSlider.value = Float(Double(index) / Double(denom))
        }
        shutterRow?.valueText = state.exposureDurationSeconds
            .map { (state.exposureMode == .custom) ? Self.formatShutter($0) : "\(Self.formatShutter($0)) (auto)" }
            ?? "auto"

        if let wbModeSegmented {
            applyWBModeUI(state.whiteBalanceMode, to: wbModeSegmented)
        }
        // WB Kelvin slider: only follow `state` while WB is `.locked`.
        if state.whiteBalanceMode == .locked,
           let wbKelvinSlider, !wbKelvinSlider.isTracking {
            wbKelvinSlider.value = state.whiteBalanceTemperature
        }
        let wbText = "\(Int(state.whiteBalanceTemperature))K"
        wbRow?.valueText = (state.whiteBalanceMode == .locked) ? wbText : "\(wbText) (auto)"

        if let focusModeSegmented {
            applyFocusModeUI(state.focusMode, to: focusModeSegmented)
        }
        // Lens slider: only follow `state` while focus is `.locked`.
        if state.focusMode == .locked,
           let lensSlider, !lensSlider.isTracking {
            lensSlider.value = state.lensPosition
        }
        let lensText = String(format: "%.2f", state.lensPosition)
        focusRow?.valueText = (state.focusMode == .locked) ? lensText : "\(lensText) (auto)"

        applyDisabledStates(from: state)
    }

    /// Drive the disabled-with-toast pattern from the current camera state. Each control
    /// the user could touch has a single rule about when AVFoundation will ignore (or
    /// silently fight back against) the change — encode it here and surface it via
    /// `PRMSettingsRow.setDisabled(message:)` so the user gets a clear reason instead of
    /// a no-op.
    private func applyDisabledStates(from state: PRMCameraState) {
        // EV bias has no effect under custom exposure (manual ISO/shutter is the only
        // exposure path; bias is a pre-trim on the auto-exposure target).
        evRow?.setDisabled(message: state.exposureMode == .custom
            ? "EV bias is ignored under custom exposure"
            : nil)

        // The Custom Exposure preset doesn't apply while the device is mid-recording —
        // changing exposure modes during an in-flight movie file output is allowed by
        // AVFoundation but ends up clipped at the next sample boundary, which produces
        // a visible flicker. The Night mode also drives its own custom exposure during
        // long-exposure composition, so block during that capture path too. The preset
        // row's content is the segmented directly (no `PRMSettingsRow` handle is stored)
        // — using `isEnabled` + `alpha` on the segmented itself is sufficient. The user
        // gets standard iOS disabled-segment styling and the segmented swallows taps.
        let recording = recordingTimer != nil
        let customExposureDisabled = recording || mode == .night
        customExposureSegmented?.isEnabled = !customExposureDisabled
        customExposureSegmented?.alpha = customExposureDisabled ? 0.45 : 1.0

        // ISO + Shutter sliders work in any exposure mode (drag promotes to .custom under
        // the hood), so they're never structurally disabled — but they're meaningless
        // during a Night composite (long-exposure capture overrides). Same with WB and
        // Focus lock sliders during recording: changes mid-record produce visible jumps.
        if mode == .night, nightDuration != .auto {
            isoRow?.setDisabled(message: "ISO is fixed during Night exposure")
            shutterRow?.setDisabled(message: "Shutter is fixed during Night exposure")
        } else {
            isoRow?.setDisabled(message: nil)
            shutterRow?.setDisabled(message: nil)
        }

        // WB Kelvin slider auto-promotes to .locked, so it works in any WB mode.
        // Lens slider auto-promotes to .locked focus, so it works in any focus mode.
        // The remaining disable cases are mid-recording (visible jumps).
        let recordingMessage: String? = recording ? "Setting locked while recording" : nil
        wbRow?.setDisabled(message: recordingMessage)
        // Custom lens position is not supported on virtual devices on recent iOS — the
        // `setFocusModeLocked(lensPosition:)` setter throws even when
        // `isFocusModeSupported(.locked)` reports true. Surface that as a disabled
        // row with a toast pointing at manual exposure (which auto-swaps to wide).
        let focusUnsupportedMessage = (camera.device?.supportsCustomLensPosition == false)
            ? "Manual focus needs the wide camera. Drag ISO / Shutter to switch."
            : nil
        focusRow?.setDisabled(message: recordingMessage ?? focusUnsupportedMessage)
    }

    /// Find the stop index whose value is closest (in log-shutter space) to `seconds`.
    /// Log-space comparison matches how photographers think about shutter stops —
    /// `1/60` is "one stop" from `1/30`, not "half a stop."
    private static func nearestStopIndex(to seconds: Double, in stops: [Double]) -> Int {
        guard seconds > 0, !stops.isEmpty else { return 0 }
        let target = log(seconds)
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (index, stop) in stops.enumerated() where stop > 0 {
            let d = abs(log(stop) - target)
            if d < bestDistance {
                bestDistance = d
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Reflect `mode` into the 4-segment Exposure Mode picker (Locked / Auto / Cont /
    /// Custom). `row` is optional so the same helper works from both the segmented's own
    /// action handler (which has the row) and from `syncDrawerControls` (which doesn't —
    /// it walks the segmented directly).
    private func applyExposureModeUI(
        _ mode: AVCaptureDevice.ExposureMode,
        to segmented: UISegmentedControl,
        row: PRMSettingsRow?
    ) {
        let index: Int
        let label: String
        switch mode {
        case .locked: index = 0; label = "locked"
        case .autoExpose: index = 1; label = "auto"
        case .continuousAutoExposure: index = 2; label = "continuous"
        case .custom: index = 3; label = "custom"
        @unknown default: index = 1; label = "auto"
        }
        segmented.selectedSegmentIndex = index
        row?.valueText = label
    }

    private func applyWBModeUI(_ mode: AVCaptureDevice.WhiteBalanceMode, to segmented: UISegmentedControl) {
        switch mode {
        case .locked: segmented.selectedSegmentIndex = 0
        case .autoWhiteBalance: segmented.selectedSegmentIndex = 1
        case .continuousAutoWhiteBalance: segmented.selectedSegmentIndex = 2
        @unknown default: segmented.selectedSegmentIndex = 1
        }
    }

    private func applyFocusModeUI(_ mode: AVCaptureDevice.FocusMode, to segmented: UISegmentedControl) {
        switch mode {
        case .locked: segmented.selectedSegmentIndex = 0
        case .autoFocus: segmented.selectedSegmentIndex = 1
        case .continuousAutoFocus: segmented.selectedSegmentIndex = 2
        @unknown default: segmented.selectedSegmentIndex = 2
        }
    }

    /// Push a (duration, iso) pair into the ISO + Shutter sliders without firing their
    /// `.valueChanged` actions (which would re-call the camera setter).
    private func syncManualExposureControls(durationSeconds: Double, iso: Float) {
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }
        if let isoSlider {
            isoSlider.value = iso
            isoRow?.valueText = "\(Int(iso))"
        }
        if let shutterSlider, !shutterStops.isEmpty {
            let index = Self.nearestStopIndex(to: durationSeconds, in: shutterStops)
            let denom = max(shutterStops.count - 1, 1)
            shutterSlider.value = Float(Double(index) / Double(denom))
            shutterRow?.valueText = Self.formatShutter(durationSeconds)
        }
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Toasts a user-friendly message *and* logs the underlying error with full detail
    /// to `PRMLogger.capture` so failures show up in Console.app even when the user
    /// missed the transient toast. `context` is the operation that failed (e.g.
    /// "Capture", "Switch camera") — used as both the toast prefix and the log tag.
    private func reportError(_ error: Error, context: String) {
        let detail = String(describing: error)
        PRMLogger.capture.error("\(context, privacy: .public) failed: \(detail, privacy: .public)")
        showToast("\(context) failed: \(error.localizedDescription)")
    }

    /// Standalone log channel for non-error notices we'd like to see in Console without
    /// pulling the user's attention to a toast (mode switches, lens picks, etc.). Same
    /// category as `reportError` so they sort together in Console.
    private func logInfo(_ message: String) {
        PRMLogger.capture.info("\(message, privacy: .public)")
    }

    private func showToast(_ message: String) {
        Task { @MainActor in
            let toast = PaddedLabel()
            toast.text = message
            toast.textColor = .white
            toast.font = .systemFont(ofSize: 13, weight: .medium)
            toast.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            view.addSubview(toast)
            // Sits just below the recording / Live Photo indicator row so all transient
            // notices stack in the same top region of the screen.
            toast.snp.makeConstraints {
                $0.centerX.equalToSuperview()
                $0.top.equalTo(recordingTimerLabel.snp.bottom).offset(12)
                $0.height.equalTo(36)
            }
            try? await Task.sleep(for: .seconds(1.5))
            UIView.animate(withDuration: 0.3, animations: { toast.alpha = 0 }, completion: { _ in
                toast.removeFromSuperview()
            })
        }
    }
}

// MARK: - Subviews

private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init() instead")
    }
}

private final class ToolbarChip: UIControl {
    var onTap: (() -> Void)?
    private let imageView = UIImageView()
    private var isActive = false

    init(symbol: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        imageView.image = UIImage(systemName: symbol)
        imageView.tintColor = .white
        imageView.contentMode = .center
        addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }
        snp.makeConstraints { $0.size.equalTo(CGSize(width: 38, height: 38)) }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(symbol:) instead")
    }

    func setSymbol(_ symbol: String, active: Bool) {
        imageView.image = UIImage(systemName: symbol)
        setActive(active)
    }

    func setActive(_ active: Bool) {
        isActive = active
        backgroundColor = active
            ? UIColor.systemYellow.withAlphaComponent(0.25)
            : UIColor.white.withAlphaComponent(0.08)
        imageView.tintColor = active ? .systemYellow : .white
    }

    @objc private func handleTap() {
        onTap?()
    }
}

private final class TextChip: UIControl {
    var onTap: (() -> Void)?
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textAlignment = .center
        addSubview(label)
        label.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
        }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:)")
    }

    @objc private func handleTap() {
        onTap?()
    }
}

private final class LensPill: UIControl {
    var onTap: (() -> Void)?

    /// The raw zoom factor this pill activates. Used as the fallback when AVFoundation
    /// doesn't expose `activePrimaryConstituentDevice` — the highest-zoom lens whose
    /// `zoomFactor ≤ currentZoom` is the one feeding frames.
    let zoomFactor: CGFloat

    /// User-facing zoom multiplier — what the label reads (`0.5`, `1`, `5`).
    let displayZoomFactor: CGFloat

    /// The physical constituent lens this pill represents (ultrawide / wide / telephoto).
    /// Matched against `PRMCameraState.activePrimaryDeviceType` so the highlight reflects
    /// the lens AVFoundation is *actually* feeding, even when that differs from the
    /// switchover bucket (e.g. low light forces a fallback to wide at 5× displayed).
    let deviceType: AVCaptureDevice.DeviceType?

    /// Whether this pill represents a real lens or a virtual sensor crop (e.g. the 2×
    /// crop on iPhones with a 48MP main sensor). Crops don't trigger the lens-switch
    /// overlay since the physical lens doesn't change.
    let kind: PRMLens.Kind

    private let label = UILabel()
    /// Custom border layer so virtual sensor-crop chips can render dashed strokes
    /// (signaling "not a real lens, just a digital crop"). `CALayer.borderWidth`
    /// doesn't support dashed patterns, so we draw the border via a shape layer
    /// instead. The shape layer's path is updated in `layoutSubviews` to match the
    /// current capsule bounds.
    private let borderShape = CAShapeLayer()
    private(set) var isActive: Bool = false

    init(title: String, zoomFactor: CGFloat, displayZoomFactor: CGFloat, deviceType: AVCaptureDevice.DeviceType?, kind: PRMLens.Kind) {
        self.zoomFactor = zoomFactor
        self.displayZoomFactor = displayZoomFactor
        self.deviceType = deviceType
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerCurve = .continuous
        borderShape.fillColor = nil
        borderShape.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        borderShape.lineWidth = 0.5
        if kind == .nativeResolutionCrop {
            // Dashed pattern for virtual chips. ~4pt dash + ~3pt gap reads clearly at the
            // pill height and stays distinct from the solid physical-lens chips.
            borderShape.lineDashPattern = [4, 3]
        }
        layer.addSublayer(borderShape)
        label.text = title
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
        label.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)) }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    /// Pill is a capsule (corner radius = half the height). Doing this in `layoutSubviews`
    /// keeps the shape correct across Dynamic Type changes since the height tracks the
    /// label's intrinsic size. The border shape's path is rebuilt for the new bounds.
    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        // Inset by half the stroke width so the stroke sits visually on the pill edge
        // rather than half-clipped by the capsule mask.
        let inset = borderShape.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        borderShape.path = UIBezierPath(roundedRect: rect, cornerRadius: max(0, radius - inset)).cgPath
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        // Match the init's inactive background (`.black.withAlpha(0.45)`) so toggling
        // off doesn't lighten the pill — both states need to stay readable on top of
        // the live preview, which is what the dark tint was chosen for.
        backgroundColor = active
            ? UIColor.systemYellow.withAlphaComponent(0.25)
            : UIColor.black.withAlphaComponent(0.45)
        borderShape.strokeColor = (active
            ? UIColor.systemYellow.withAlphaComponent(0.85)
            : UIColor.white.withAlphaComponent(0.25)).cgColor
        label.textColor = active ? .systemYellow : .white
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - LiveCaptureIndicator

/// Apple Camera–style "LIVE" pill that appears while a Live Photo capture is in flight.
/// Pulses its alpha at ~1Hz so the user has a visible "still capturing the paired movie"
/// affordance — the still finishes first, then the ~1.5s paired movie writes after.
private final class LiveCaptureIndicator: UIView {
    private let icon = UIImageView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.95)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        icon.image = UIImage(
            systemName: "livephoto",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        icon.tintColor = .black
        icon.contentMode = .scaleAspectFit
        label.text = "LIVE"
        label.textColor = .black
        label.font = .systemFont(ofSize: 11, weight: .heavy)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    func setActive(_ active: Bool) {
        if active {
            isHidden = false
            alpha = 1
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(
                withDuration: 0.8,
                delay: 0,
                options: [.autoreverse, .repeat, .curveEaseInOut, .allowUserInteraction],
                animations: { [self] in alpha = 0.45 }
            )
        } else {
            layer.removeAllAnimations()
            isHidden = true
            alpha = 1
        }
    }
}

// MARK: - NightCaptureIndicator

/// Apple-style "NIGHT N/total" pill that pulses while a night-mode stack is in flight.
/// Shares centerX/centerY with the recording timer and Live Photo pill so all three swap
/// in place without layout shift.
private final class NightCaptureIndicator: UIView {
    private let icon = UIImageView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.95)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        icon.image = UIImage(
            systemName: "moon.stars.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .heavy)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// `frame == 0` shows the bare `NIGHT` label (no progress yet); subsequent ticks show
    /// `NIGHT n/total`. Pulses alpha to mirror the Live Photo pill's rhythm.
    func setActive(_ active: Bool, frame: Int = 0, total: Int = 0) {
        if active {
            isHidden = false
            alpha = 1
            label.text = frame == 0 ? "NIGHT" : "NIGHT \(frame)/\(total)"
            guard layer.animation(forKey: "pulse") == nil else { return }
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(
                withDuration: 0.8,
                delay: 0,
                options: [.autoreverse, .repeat, .curveEaseInOut, .allowUserInteraction],
                animations: { [self] in alpha = 0.45 }
            )
        } else {
            layer.removeAllAnimations()
            isHidden = true
            alpha = 1
        }
    }
}

// MARK: - ModePillStrip

private final class ModePillStrip: UIView {
    var onSelect: ((Int) -> Void)?
    var onDisabledTap: ((String) -> Void)?
    var selectedIndex: Int = 0 {
        didSet { applySelection() }
    }

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var pills: [TextChip] = []
    private var disabledMessages: [Int: String] = [:]
    init() {
        super.init(frame: .zero)
        addSubview(scrollView)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
        scrollView.addSubview(stackView)
        stackView.axis = .horizontal
        stackView.spacing = 6
        // Pin top/bottom to the content layout guide so the scroll view sizes its
        // contentSize.height from the stack. Center horizontally inside the frame layout
        // guide so short strips look centered; allow the stack to overflow the frame
        // (negative leading/trailing) when there are too many pills — scroll view's
        // content layout guide expands and the strip scrolls.
        stackView.snp.makeConstraints {
            $0.top.bottom.equalTo(scrollView.contentLayoutGuide)
            $0.leading.greaterThanOrEqualTo(scrollView.contentLayoutGuide)
            $0.trailing.lessThanOrEqualTo(scrollView.contentLayoutGuide)
            $0.centerX.equalTo(scrollView.frameLayoutGuide)
            $0.height.equalTo(scrollView.frameLayoutGuide)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    func setModes(_ labels: [String]) {
        for pill in pills {
            pill.removeFromSuperview()
        }
        pills = []
        disabledMessages.removeAll()
        for (index, label) in labels.enumerated() {
            let pill = TextChip(title: label)
            pill.onTap = { [weak self] in
                guard let self else { return }
                if let message = disabledMessages[index] {
                    onDisabledTap?(message)
                    return
                }
                selectedIndex = index
                onSelect?(index)
            }
            pills.append(pill)
            stackView.addArrangedSubview(pill)
        }
        applySelection()
    }

    func indexOf(label: String) -> Int? {
        for (index, pill) in pills.enumerated() where (pill.subviews.first as? UILabel)?.text == label {
            return index
        }
        return nil
    }

    /// Replace the visible text on a single pill without rebuilding the strip — useful for
    /// chips whose label tracks live state (Night AUTO showing its resolved duration).
    func setLabel(at index: Int, to text: String) {
        guard index >= 0, index < pills.count else { return }
        (pills[index].subviews.first as? UILabel)?.text = text
    }

    /// Marks a pill as disabled. Disabled pills render at reduced opacity and route
    /// taps to `onDisabledTap` with the supplied message instead of changing the
    /// selected index. Pass `nil` to re-enable.
    func setDisabled(at index: Int, message: String?) {
        guard index >= 0, index < pills.count else { return }
        if let message {
            disabledMessages[index] = message
        } else {
            disabledMessages.removeValue(forKey: index)
        }
        applySelection()
    }

    private func applySelection() {
        for (index, pill) in pills.enumerated() {
            let active = index == selectedIndex
            let disabled = disabledMessages[index] != nil
            pill.backgroundColor = active
                ? UIColor.systemYellow
                : UIColor.white.withAlphaComponent(0.10)
            (pill.subviews.first as? UILabel)?.textColor = active ? .black : .white
            pill.alpha = disabled ? 0.35 : 1.0
        }
    }
}

// MARK: - ModePicker

/// Two-row capture-mode picker: primary capture style on top, contextual variants underneath.
///
/// The primary row switches between `PHOTO / VIDEO / NIGHT`. The variant row content depends
/// on the active primary: Photo → STANDARD / LIVE / PORTRAIT / BURST; Video → STANDARD / SLO-MO
/// (when supported); Night → AUTO / 1s / 3s / 5s. The variant row collapses to zero-height
/// when the current primary exposes no variants.
private final class ModePicker: UIView {
    enum Primary: CaseIterable, Equatable {
        case photo, video, night

        var label: String {
            switch self {
            case .photo: "PHOTO"
            case .video: "VIDEO"
            case .night: "NIGHT"
            }
        }
    }

    enum Variant: Equatable {
        case standard
        case live
        case portrait
        case burst
        case video24
        case video30
        case slowMo
        case nightAuto
        case night1s
        case night3s
        case night5s

        var label: String {
            switch self {
            case .standard: "STANDARD"
            case .live: "LIVE"
            case .portrait: "PORTRAIT"
            case .burst: "BURST"
            case .video24: "24"
            case .video30: "30"
            case .slowMo: "SLO-MO"
            case .nightAuto: "AUTO"
            case .night1s: "1s"
            case .night3s: "3s"
            case .night5s: "5s"
            }
        }
    }

    var onChange: ((Primary, Variant) -> Void)?
    var onDisabledVariantTap: ((String) -> Void)?

    /// Whether the slo-mo variant is offered under VIDEO. Driven by `device.supportsSlowMotion`.
    var supportsSlowMotion: Bool = false {
        didSet { rebuildVariants() }
    }

    private(set) var primary: Primary = .photo
    private(set) var variant: Variant = .standard

    private let primaryRow = ModePillStrip()
    private let variantRow = ModePillStrip()
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }

        stack.addArrangedSubview(primaryRow)
        stack.addArrangedSubview(variantRow)
        primaryRow.snp.makeConstraints { $0.height.equalTo(34) }
        variantRow.snp.makeConstraints { $0.height.equalTo(28) }

        primaryRow.setModes(Primary.allCases.map(\.label))
        primaryRow.selectedIndex = 0
        primaryRow.onSelect = { [weak self] index in
            guard let self, index >= 0, index < Primary.allCases.count else { return }
            self.primary = Primary.allCases[index]
            // Seed a sensible default variant per primary: 30 fps matches iOS Camera for
            // VIDEO, AUTO for NIGHT, STANDARD for PHOTO. `rebuildVariants` re-clamps if
            // the seed isn't in the variant list (e.g. STANDARD on a video-only device).
            self.variant = switch self.primary {
            case .photo: .standard
            case .video: .video30
            case .night: .nightAuto
            }
            self.rebuildVariants()
            self.onChange?(self.primary, self.variant)
        }

        variantRow.onSelect = { [weak self] index in
            guard let self else { return }
            let variants = self.variants(for: self.primary)
            guard index >= 0, index < variants.count else { return }
            self.variant = variants[index]
            self.onChange?(self.primary, self.variant)
        }
        variantRow.onDisabledTap = { [weak self] message in
            self?.onDisabledVariantTap?(message)
        }

        rebuildVariants()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// Disables or re-enables a variant pill. Disabled pills render at reduced opacity
    /// and route taps to `onDisabledVariantTap` with `message`. Pass `nil` to clear.
    /// No-op if `variant` isn't in the current primary's variant list.
    func setVariantDisabled(_ variant: Variant, message: String?) {
        let variants = self.variants(for: primary)
        guard let index = variants.firstIndex(of: variant) else { return }
        variantRow.setDisabled(at: index, message: message)
    }

    /// Replace the displayed label for a single variant pill. Used so the Night AUTO
    /// chip can show its resolved duration (e.g. `AUTO 3s`) without changing the
    /// underlying `Variant.nightAuto` value the controller dispatches on.
    func setVariantLabel(for variant: Variant, to text: String) {
        let variants = self.variants(for: primary)
        guard let index = variants.firstIndex(of: variant) else { return }
        variantRow.setLabel(at: index, to: text)
    }

    /// Programmatically select a (primary, variant) pair — used by the long-press-shutter shortcut
    /// to flip from photo into video without going through a tap.
    func select(primary: Primary, variant: Variant) {
        guard let primaryIndex = Primary.allCases.firstIndex(of: primary) else { return }
        primaryRow.selectedIndex = primaryIndex
        self.primary = primary
        rebuildVariants()
        let variants = self.variants(for: primary)
        if let variantIndex = variants.firstIndex(of: variant) {
            variantRow.selectedIndex = variantIndex
            self.variant = variant
        } else {
            variantRow.selectedIndex = 0
            self.variant = variants.first ?? .standard
        }
    }

    private func variants(for primary: Primary) -> [Variant] {
        switch primary {
        case .photo: [.standard, .live, .portrait, .burst]
        case .video:
            // 30 fps is the iOS Camera default; 24 fps gives a film cadence. Higher fps
            // (60+) was dropped because forcing a format switch from the `.photo` preset
            // would resize the preview and add latency — see `VideoFPS` doc comment.
            // Slo-mo (120/240 fps) is its own variant when supported.
            supportsSlowMotion
                ? [.video24, .video30, .slowMo]
                : [.video24, .video30]
        case .night: [.nightAuto, .night1s, .night3s, .night5s]
        }
    }

    private func rebuildVariants() {
        let variants = self.variants(for: primary)
        variantRow.setModes(variants.map(\.label))
        variantRow.isHidden = variants.isEmpty
        if !variants.isEmpty {
            let index = variants.firstIndex(of: variant) ?? 0
            variantRow.selectedIndex = index
            variant = variants[index]
        } else {
            variant = .standard
        }
    }
}

// swiftlint:enable file_length type_body_length
