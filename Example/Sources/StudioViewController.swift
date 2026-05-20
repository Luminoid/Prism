@preconcurrency import AVFoundation
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
    private let drawer = PRMSettingsDrawerView(title: "Camera Settings")

    // MARK: - State

    private enum Mode: Equatable {
        case photo, live, portrait, pano, video, slowMo, night

        var label: String {
            switch self {
            case .photo: "PHOTO"
            case .live: "LIVE"
            case .portrait: "PORTRAIT"
            case .pano: "PANO"
            case .video: "VIDEO"
            case .slowMo: "SLO-MO"
            case .night: "NIGHT"
            }
        }
    }

    private var mode: Mode = .photo {
        didSet { applyModeChange() }
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

    private var flashSetting: FlashSetting = .auto
    private var timerSetting: TimerSetting = .off
    private var burstEnabled = false

    private var initialPinchZoom: CGFloat = 1.0
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    private var lastDevice: PRMCameraDevice?

    /// Drives `PRMCamera.rampZoom` / `.cancelZoomRamp` — smooth 1.0×→2.0× ramp at rate 1.0.
    fileprivate var isZoomRamping = false

    private var rotationStreamTask: Task<Void, Never>?

    // Error + interruption observers (toasts surfaced via showToast).
    private var errorStreamTask: Task<Void, Never>?
    private var interruptionStreamTask: Task<Void, Never>?
    private var stateStreamTask: Task<Void, Never>?

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
        rotationStreamTask = nil
        errorStreamTask = nil
        interruptionStreamTask = nil
        stateStreamTask = nil
        Task { await camera.stop() }
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func flipCameraSync() {
        Task { await flipCamera() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(previewView)
        previewView.snp.makeConstraints { $0.edges.equalToSuperview() }
        // Preview frames arrive pre-rotated via the data-output connection's
        // `videoRotationAngle`, set from `PRMRotationCoordinator` in `bootCamera()`.
        // MTKView itself renders identity.

        view.addSubview(aspectMask)
        aspectMask.snp.makeConstraints { $0.edges.equalToSuperview() }

        view.addSubview(gridOverlay)
        gridOverlay.snp.makeConstraints { $0.edges.equalToSuperview() }
        gridOverlay.isGridVisible = false

        levelIndicator.lineColor = UIColor.white.withAlphaComponent(0.7)
        levelIndicator.leveledColor = .systemYellow
        levelIndicator.lineWidth = 1.5
        view.addSubview(levelIndicator)
        levelIndicator.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.centerY.equalToSuperview()
            $0.width.equalTo(140)
            $0.height.equalTo(140)
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
        recordingTimerLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(16)
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
            config.includesMovieFileOutput = true
            config.enableLivePhoto = true
            config.enableDepthDataDelivery = true
            config.enablePortraitEffectsMatteDelivery = true
            try await camera.configure(config)
        } catch {
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
                showToast("Runtime error: \(error.localizedDescription)")
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

        await rebindRotationCoordinator()

        await camera.start()
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
            let snapped = lens.snapping().focalLength35mm
            let button = LensPill(title: "\(Int(snapped))mm")
            button.onTap = { [weak self] in
                Task { await self?.camera.setZoom(lens.zoomFactor) }
            }
            lensStrip.addArrangedSubview(button)
        }
    }

    // MARK: - Mode picker

    private func populateModeStrip() {
        modePicker.supportsSlowMotion = camera.device?.supportsSlowMotion == true
        modePicker.select(primary: .photo, variant: .standard)
        applyModeChange(primary: .photo, variant: .standard)
    }

    /// Translates a picker (primary, variant) selection into the `Mode` enum the rest of the
    /// controller already understands. Burst is folded into `.photo` via `burstEnabled`.
    private func applyModeChange(primary: ModePicker.Primary, variant: ModePicker.Variant) {
        burstEnabled = (primary == .photo && variant == .burst)
        switch primary {
        case .photo:
            switch variant {
            case .live: mode = .live
            case .portrait: mode = .portrait
            case .standard, .burst: mode = .photo
            case .slowMo: mode = .photo
            }
        case .video:
            mode = variant == .slowMo ? .slowMo : .video
        case .night:
            mode = .night
        case .pano:
            mode = .pano
        }
    }

    private func applyModeChange() {
        Task {
            switch mode {
            case .photo, .live, .portrait, .pano, .night:
                await camera.resetFrameRate()
                shutter.setMode(.photo)
            case .video:
                await camera.resetFrameRate()
                shutter.setMode(.recording)
            case .slowMo:
                let target: Float64 = (camera.device?.maxFrameRate ?? 30) >= 240 ? 240 : 120
                await camera.setFrameRate(target)
                shutter.setMode(.recording)
            }
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
        case .pano:
            showToast("Pano stitching not yet implemented")
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
                showToast("Capture failed: \(error.localizedDescription)")
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
                showToast("Burst failed: \(error.localizedDescription)")
            }
        }
    }

    private func captureLivePhoto() {
        guard let photoCapture else { return }
        let settings = makePhotoSettings(flash: .off, quality: .quality)
        flashOverlay()
        Task {
            do {
                let live = try await photoCapture.captureLivePhoto(settings: settings)
                await saveLivePhoto(live)
            } catch {
                showToast("Live capture failed: \(error.localizedDescription)")
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
                let finalData: Data
                if let matte = portrait.portraitEffectsMatte {
                    let matteImage = CIImage(cvPixelBuffer: matte.mattingImage)
                    let filter = PRMPortraitBokehFilter(matte: matteImage, radius: 18)
                    if let source = CIImage(data: portrait.photo.data) {
                        let blurred = filter.render(source)
                        finalData = PRMImage.jpegDataPreservingMetadata(
                            from: blurred,
                            originalProperties: source.properties.merging(portrait.photo.metadata) { _, new in new },
                            context: renderContext
                        ) ?? portrait.photo.data
                    } else {
                        finalData = portrait.photo.data
                    }
                } else {
                    finalData = portrait.photo.data
                }
                await saveToPhotoLibrary(data: finalData)
            } catch {
                showToast("Portrait failed: \(error.localizedDescription)")
            }
        }
    }

    private func captureNight() {
        guard let nightCapture else { return }
        showToast("Hold still — stacking 6 frames…")
        Task {
            do {
                let photo = try await nightCapture.capture(
                    frameCount: 6,
                    perFrameDuration: 0.25,
                    iso: 800
                )
                await saveToPhotoLibrary(data: photo.data)
            } catch {
                showToast("Night failed: \(error.localizedDescription)")
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
        do {
            try await Self.writePhoto(data: data)
            if !silent { showToast("Saved to Photos") }
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func saveLivePhoto(_ live: PRMLivePhoto) async {
        guard await ensurePhotoLibraryAccess() else { return }
        let photoData = live.photo.data
        let movieURL = live.movieURL
        do {
            try await Self.writeLivePhoto(photoData: photoData, movieURL: movieURL)
            showToast("Saved Live Photo")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
            PRMTempFile.remove(movieURL)
        }
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
                showToast("Record failed: \(error.localizedDescription)")
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
                showToast("Stop failed: \(error.localizedDescription)")
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
            showToast("Save failed: \(error.localizedDescription)")
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

    private func handleShutterLongPressBegan() {
        guard mode != .live, mode != .portrait, mode != .night, mode != .pano else { return }
        if mode == .photo {
            modePicker.select(primary: .video, variant: .standard)
            applyModeChange(primary: .video, variant: .standard)
        }
        if recordingStartedAt == nil {
            startRecording()
        }
    }

    private func handleShutterLongPressEnded() {
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
        } catch {
            showToast("Switch failed: \(error.localizedDescription)")
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
        let zoom = String(format: "%.1f×", Double(state.zoomFactor))
        let iso = "ISO \(Int(state.iso))"
        let shutter = state.exposureDurationSeconds.map { duration in
            duration > 0 ? "1/\(Int(1.0 / duration))" : "n/a"
        } ?? "auto"
        let ev = String(format: "EV %+0.1f", state.exposureBias)
        let temp = "\(Int(state.whiteBalanceTemperature))K"
        let fps = state.frameRate.map { "\(Int($0))fps" } ?? ""
        let modeLabel = mode.label
        telemetryLabel.text = [modeLabel, zoom, iso, shutter, ev, temp, fps]
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showToast(_ message: String) {
        Task { @MainActor in
            let toast = PaddedLabel()
            toast.text = message
            toast.textColor = .white
            toast.font = .systemFont(ofSize: 13, weight: .medium)
            toast.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            view.addSubview(toast)
            toast.snp.makeConstraints {
                $0.centerX.equalToSuperview()
                $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-120)
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
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        layer.borderWidth = 0.5
        label.text = title
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
        label.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)) }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    @objc private func handleTap() {
        onTap?()
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

/// Two-row capture-mode picker: primary capture style on top, optional variants underneath.
///
/// The primary row is always visible and switches between `PHOTO / VIDEO / NIGHT / PANO`.
/// The variant row appears only when the current primary has variants (Photo → Live / Portrait / Burst;
/// Video → Slo-Mo if supported) and collapses to zero-height otherwise.
private final class ModePicker: UIView {
    enum Primary: CaseIterable, Equatable {
        case photo, video, night, pano

        var label: String {
            switch self {
            case .photo: "PHOTO"
            case .video: "VIDEO"
            case .night: "NIGHT"
            case .pano: "PANO"
            }
        }
    }

    enum Variant: Equatable {
        case standard
        case live
        case portrait
        case burst
        case slowMo

        var label: String {
            switch self {
            case .standard: "STANDARD"
            case .live: "LIVE"
            case .portrait: "PORTRAIT"
            case .burst: "BURST"
            case .slowMo: "SLO-MO"
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
            self.variant = .standard
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
        case .video: supportsSlowMotion ? [.standard, .slowMo] : []
        case .night, .pano: []
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
