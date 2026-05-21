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
    private let aspectCycle: [PRMAspectRatioMaskView.AspectRatio] = [.full, .ratio4x3, .ratio16x9, .ratio1x1]

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
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    private var lastDevice: PRMCameraDevice?

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
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationController?.setNavigationBarHidden(true, animated: false)
        modalPresentationCapturesStatusBarAppearance = true

        setupLayout()
        wireGestures()
        previewView.addInteraction(captureEventHelper.makeInteraction())
        captureEventHelper.onPrimaryAction = { [weak self] in self?.handleShutterTap() }
        captureEventHelper.onSecondaryAction = { [weak self] in self?.flipCameraSync() }
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
            // Start in Live-Photo-capable mode (no movie file output). `applyModeChange()`
            // dynamically attaches `AVCaptureMovieFileOutput` when the user enters
            // Video / Slo-Mo, and detaches it on return. Live Photo + Movie output are
            // mutually exclusive on the same session — see PRMCameraSession.setMovieFileOutputAttached.
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
            if let movieOutput = await self.camera.session.movieFileOutput {
                let recorder = PRMVideoRecorder(output: movieOutput)
                await MainActor.run { self.videoRecorder = recorder }
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
                deviceType: lens.deviceType
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
        let crossesLens = previouslyActive?.deviceType != button.deviceType

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

        let active: LensPill?
        if let activeType = state.activePrimaryDeviceType,
           let match = pills.first(where: { $0.deviceType == activeType }) {
            active = match
        } else {
            let sorted = pills.sorted { $0.zoomFactor < $1.zoomFactor }
            active = sorted.last { $0.zoomFactor <= state.zoomFactor + 0.001 } ?? sorted.first
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
        Task {
            // Live Photo and AVCaptureMovieFileOutput are mutually exclusive on the same
            // session: having both attached forces `isLivePhotoCaptureSupported` to false.
            // Toggle the movie output based on whether the current mode actually needs to
            // record video. Photo / Live / Portrait / Night detach the movie output so
            // Live Photo and Portrait matte work; Video / Slo-Mo re-attach it.
            let needsMovieOutput = (mode == .video || mode == .slowMo)
            do {
                try await camera.setMovieFileOutputAttached(needsMovieOutput)
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

    /// Rebuilds `videoRecorder` to point at the *current* `movieFileOutput` (which is
    /// recreated each time the movie output is reattached). Sets to nil when the output is
    /// detached so `startRecording()` exits cleanly with a toast instead of using a stale
    /// AVCaptureMovieFileOutput that AVFoundation has already torn down.
    private func refreshVideoRecorder() async {
        let movieOutput = await camera.session.movieFileOutput
        if let movieOutput {
            videoRecorder = PRMVideoRecorder(output: movieOutput)
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
        return settings
    }

    private func capturePhoto() {
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
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: .off, quality: .quality)
        flashOverlay()
        Task {
            do {
                let portrait = try await photoCapture.capturePortraitPhoto(settings: settings)
                let finalData = renderPortrait(portrait)
                await saveToPhotoLibrary(data: finalData)
            } catch {
                reportError(error, context: "Portrait")
            }
        }
    }

    /// Pick the best subject mask available for portrait bokeh and apply it.
    ///
    /// Portrait effects matte is the highest-quality mask but is only delivered on the
    /// dual / triple / TrueDepth cameras at portrait-compatible zooms. Depth data is more
    /// widely available — when matte is missing we derive a soft alpha mask from the
    /// disparity buffer (near → opaque, far → transparent) and use that. When neither
    /// is present we save the raw photo and toast so the user knows the bokeh was skipped.
    private func renderPortrait(_ portrait: PRMPortraitPhoto) -> Data {
        guard let source = CIImage(data: portrait.photo.data) else {
            return portrait.photo.data
        }

        // Resolve a usable mask. The order is matte → depth → give up. Each step is
        // guarded: AVFoundation can hand back ancillary objects whose pixel buffers
        // are internally null (deferred-photo proxies, scenes the matte network rejected),
        // and a non-nil mask wrapping a null buffer would crash PRMPortraitBokehFilter.
        let matteImage: CIImage? = if let matte = portrait.portraitEffectsMatte,
                                      let image = matteCIImage(from: matte) {
            image
        } else if let depth = portrait.depthData,
                  let image = depthMask(from: depth, targetExtent: source.extent) {
            image
        } else {
            nil
        }

        guard let matteImage else {
            logInfo("Portrait bokeh unavailable: matte=\(portrait.portraitEffectsMatte == nil ? "nil" : "present-but-empty"), depth=\(portrait.depthData == nil ? "nil" : "present-but-empty")")
            showToast("Portrait bokeh unavailable for this lens — saved standard photo")
            return portrait.photo.data
        }

        let filter = PRMPortraitBokehFilter(matte: matteImage, radius: 18)
        let blurred = filter.render(source)
        let merged = source.properties.merging(portrait.photo.metadata) { _, new in new }
        return PRMImage.jpegDataPreservingMetadata(
            from: blurred,
            originalProperties: merged,
            context: renderContext
        ) ?? portrait.photo.data
    }

    /// Builds a CIImage from `AVPortraitEffectsMatte.mattingImage`, returning `nil` if
    /// the underlying buffer is internally null (which AVFoundation silently allows
    /// even though the property is non-Optional). A nil-buffer CIImage has a `.zero`
    /// extent and would propagate emptiness downstream, so reject it here.
    private func matteCIImage(from matte: AVPortraitEffectsMatte) -> CIImage? {
        let image = CIImage(cvPixelBuffer: matte.mattingImage)
        return image.extent.isEmpty ? nil : image
    }

    /// Converts an AVDepthData buffer into a soft alpha mask sized to `targetExtent`.
    /// Disparity (1/distance) is normalized into [0, 1] — near subjects stay opaque,
    /// far background fades to transparent — and the result is scaled to match the
    /// captured photo's resolution so `PRMPortraitBokehFilter` can blend cleanly.
    /// Returns `nil` if the source disparity buffer ends up empty (depth format
    /// conversion failed, or the device delivered a placeholder with no pixels).
    private func depthMask(from depth: AVDepthData, targetExtent: CGRect) -> CIImage? {
        // Normalize to disparity if the camera delivered raw depth (distance in meters).
        let disparityDepth = depth.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depth
            : depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let raw = CIImage(cvPixelBuffer: disparityDepth.depthDataMap)
        // Reject empty buffers up front — scaling against a zero-extent CIImage would
        // divide by zero and emit the runtime warning seen on iPhone 15 Pro Max when
        // the LiDAR depth conversion returns an unfilled buffer.
        guard !raw.extent.isEmpty, raw.extent.width > 0, raw.extent.height > 0 else {
            return nil
        }
        let normalized = raw.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 2.0,
            kCIInputBrightnessKey: 0.0,
        ])
        let scaleX = targetExtent.width / raw.extent.width
        let scaleY = targetExtent.height / raw.extent.height
        return normalized.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    private func captureNight() {
        guard let nightCapture else { return }
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

    private func saveToPhotoLibrary(data: Data, silent: Bool = false) async {
        guard await ensurePhotoLibraryAccess() else { return }
        let cropped = croppedToActiveAspect(data: data)
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

    /// Crops JPEG/HEIC photo data to the currently-selected aspect ratio mask, centered
    /// on the sensor frame. Returns the original bytes when the active ratio is `.full`
    /// (no crop needed) or when decode fails. EXIF/TIFF metadata is preserved.
    private func croppedToActiveAspect(data: Data) -> Data {
        guard aspectMask.aspectRatio != .full else { return data }
        guard let source = CIImage(data: data) else { return data }
        // `cropRect(in:)` is aspect-only, not coordinate-dependent — the returned rect is
        // a centered subrect with the target aspect inside the supplied bounds. Passing
        // the source image's full extent gives us the same crop applied in sensor space.
        let cropRect = aspectMask.cropRect(in: source.extent)
        let cropped = source.cropped(to: cropRect)
        // `cropped(to:)` keeps the original extent's origin; translating back to (0,0)
        // makes the JPEG writer produce a tight image instead of a same-size canvas
        // with everything outside the crop set to transparent.
        let translated = cropped.transformed(
            by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        )
        // Preserve EXIF/TIFF so the saved photo retains the camera metadata.
        let originalProperties = readImageProperties(from: data)
        return PRMImage.jpegDataPreservingMetadata(
            from: translated,
            originalProperties: originalProperties,
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
        let active = aspectMask.aspectRatio != .full
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
        do {
            pipeline.isEnabled = false
            try await camera.switchCamera(to: next)
            pipeline.isEnabled = true
            previewView.mirroring = (next == .front)
            rebuildLensStrip()
            populateModeStrip()
            await rebindRotationCoordinator()
            await applyDefaultFocalLength()
        } catch {
            reportError(error, context: "Switch camera")
            pipeline.isEnabled = true
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: previewView)
        let devicePoint = previewView.texturePoint(fromViewPoint: viewPoint)
        focusIndicator.show(at: viewPoint, in: view)
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
            let target = initialPinchZoom * gesture.scale
            Task { await camera.setZoom(target) }
        default: break
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
    }
}

// MARK: - Drawer row builders

extension StudioViewController {
    private func makeExposureModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont"])
        segmented.selectedSegmentIndex = 1
        let row = PRMSettingsRow(
            symbolName: "lock.shield",
            title: "Exposure Mode",
            valueText: "auto",
            content: segmented
        )
        segmented.addAction(UIAction { [weak self, weak row] _ in
            let mode: AVCaptureDevice.ExposureMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .locked; row?.valueText = "locked"
            case 1: mode = .autoExpose; row?.valueText = "auto"
            default: mode = .continuousAutoExposure; row?.valueText = "continuous"
            }
            Task { await self?.camera.setExposureMode(mode) }
        }, for: .valueChanged)
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
            guard let self else { return }
            let (duration, iso, label): (CMTime, Float, String) = switch segmented.selectedSegmentIndex {
            case 0: (CMTime(value: 1, timescale: 500), max(50, device.isoRange.lowerBound), "1/500 · ISO \(Int(device.isoRange.lowerBound))")
            case 1: (CMTime(value: 1, timescale: 60), min(400, device.isoRange.upperBound), "1/60 · ISO 400")
            default: (CMTime(value: 1, timescale: 30), min(1600, device.isoRange.upperBound), "1/30 · ISO 1600")
            }
            row?.valueText = label
            Task { await camera.setCustomExposure(duration: duration, iso: iso) }
        }, for: .valueChanged)
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
            let mode: AVCaptureDevice.WhiteBalanceMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .locked; row?.valueText = "locked"
            case 1: mode = .autoWhiteBalance; row?.valueText = "auto"
            default: mode = .continuousAutoWhiteBalance; row?.valueText = "continuous"
            }
            Task { await self?.camera.setWhiteBalanceMode(mode) }
        }, for: .valueChanged)
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
            let mode: AVCaptureDevice.FocusMode
            switch segmented.selectedSegmentIndex {
            case 0: mode = .locked; row?.valueText = "locked"
            case 1: mode = .autoFocus; row?.valueText = "auto"
            default: mode = .continuousAutoFocus; row?.valueText = "continuous"
            }
            guard let self else { return }
            let session = camera.session
            Task { @PRMCameraActor in
                guard let device = session.videoDevice else { return }
                try? device.prm_setFocusMode(mode)
            }
        }, for: .valueChanged)
        return row
    }

    private func makeZoomRampRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let button = UIButton(type: .system)
        button.setTitle("Ramp →", for: .normal)
        button.setTitleColor(.systemYellow, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        let target: CGFloat = min(2.0, device.maxZoomFactor)
        let row = PRMSettingsRow(
            symbolName: "arrow.up.right.and.arrow.down.left.rectangle",
            title: "Smooth Ramp",
            valueText: "→ \(String(format: "%.1f×", target))",
            content: button
        )
        button.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            if isZoomRamping {
                Task { await self.camera.cancelZoomRamp() }
                isZoomRamping = false
                row?.valueText = "→ \(String(format: "%.1f×", target))"
                button.setTitle("Ramp →", for: .normal)
            } else {
                Task { await self.camera.rampZoom(to: target, rate: 1.0) }
                isZoomRamping = true
                row?.valueText = "ramping…"
                button.setTitle("Cancel", for: .normal)
            }
        }, for: .touchUpInside)
        return row
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
        }, for: .valueChanged)
        return row
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
            let bias = slider.value
            row?.valueText = String(format: "%+0.1f", bias)
            Task { await self?.camera.setExposureBias(bias) }
        }, for: .valueChanged)
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
            row?.valueText = "auto"
            Task { await self?.camera.setExposureMode(.continuousAutoExposure) }
        }
        slider.addAction(UIAction { [weak self, weak row] _ in
            let iso = slider.value
            row?.valueText = "\(Int(iso))"
            Task { await self?.camera.setISO(iso) }
        }, for: .valueChanged)
        return row
    }

    private func makeShutterRow(device _: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0.5
        let stops: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1.0]
        let row = PRMSettingsRow(
            symbolName: "stopwatch",
            title: "Shutter",
            valueText: "auto",
            content: slider
        )
        slider.addAction(UIAction { [weak self, weak row] _ in
            let normalized = slider.value
            let index = max(0, min(stops.count - 1, Int(round(Double(normalized) * Double(stops.count - 1)))))
            let seconds = stops[index]
            row?.valueText = "1/\(Int(round(1.0 / seconds)))"
            Task { await self?.camera.setShutterSpeed(seconds: seconds) }
        }, for: .valueChanged)
        return row
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
                row?.valueText = "\(Int(entry.preset.temperature))K"
                kelvinSlider.value = entry.preset.temperature
                Task { await self?.camera.lockWhiteBalance(preset: entry.preset) }
            }
            chips.addArrangedSubview(chip)
        }
        kelvinSlider.addAction(UIAction { [weak self, weak row] _ in
            let kelvin = kelvinSlider.value
            row?.valueText = "\(Int(kelvin))K"
            let values = AVCaptureDevice.PRMTemperatureAndTint(temperature: kelvin, tint: 0)
            Task { await self?.camera.lockWhiteBalance(values) }
        }, for: .valueChanged)
        stack.addArrangedSubview(kelvinSlider)
        stack.addArrangedSubview(chips)
        return row
    }

    private func makeFocusRow() -> PRMSettingsRow {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        let lensSlider = UISlider()
        lensSlider.minimumValue = 0
        lensSlider.maximumValue = 1
        lensSlider.value = camera.state.lensPosition
        let label = UILabel()
        label.textColor = UIColor.white.withAlphaComponent(0.6)
        label.font = .systemFont(ofSize: 11)
        label.text = "Drag to lock focus distance"
        stack.addArrangedSubview(lensSlider)
        stack.addArrangedSubview(label)
        let row = PRMSettingsRow(
            symbolName: "scope",
            title: "Focus",
            valueText: String(format: "%.2f", camera.state.lensPosition),
            content: stack
        )
        lensSlider.addAction(UIAction { [weak self, weak row] _ in
            let pos = lensSlider.value
            row?.valueText = String(format: "%.2f", pos)
            Task { await self?.camera.setLensPosition(pos) }
        }, for: .valueChanged)
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
        // Apple Camera convention: shutter has an `s` suffix (`1/60s`) so it's visually
        // distinct from frame-rate readings like `60fps`. Sub-second shutters render as
        // reciprocal-of-seconds; whole-second exposures (night mode) render as `2.5s`.
        let shutter = state.exposureDurationSeconds.map { duration -> String in
            guard duration > 0 else { return "n/a" }
            return duration >= 1.0
                ? String(format: "%.1fs", duration)
                : "1/\(Int(1.0 / duration))s"
        } ?? "auto"
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

    private let label = UILabel()
    private(set) var isActive: Bool = false

    init(title: String, zoomFactor: CGFloat, displayZoomFactor: CGFloat, deviceType: AVCaptureDevice.DeviceType?) {
        self.zoomFactor = zoomFactor
        self.displayZoomFactor = displayZoomFactor
        self.deviceType = deviceType
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.borderWidth = 0.5
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
    /// label's intrinsic size.
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
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
        layer.borderColor = (active
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
    var selectedIndex: Int = 0 {
        didSet { applySelection() }
    }

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var pills: [TextChip] = []

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
        for (index, label) in labels.enumerated() {
            let pill = TextChip(title: label)
            pill.onTap = { [weak self] in
                self?.selectedIndex = index
                self?.onSelect?(index)
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

    private func applySelection() {
        for (index, pill) in pills.enumerated() {
            let active = index == selectedIndex
            pill.backgroundColor = active
                ? UIColor.systemYellow
                : UIColor.white.withAlphaComponent(0.10)
            (pill.subviews.first as? UILabel)?.textColor = active ? .black : .white
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

        rebuildVariants()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
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
