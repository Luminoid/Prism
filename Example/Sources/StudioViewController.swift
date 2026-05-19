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
    private let modeStrip = ModePillStrip()
    private let shutter = PRMShutterButton()
    private let switchCameraButton = UIButton(type: .system)
    private let gridOverlay = PRMGridView()
    private let aspectMask = PRMAspectRatioMaskView()
    private let levelIndicator = PRMLevelIndicatorView()
    private let focusIndicator = PRMFocusIndicatorView()
    private let recordingTimerLabel = PaddedLabel()
    private let countdownLabel = UILabel()
    private let torchButton = ToolbarChip(symbol: "bolt.slash.fill")
    private let gridButton = ToolbarChip(symbol: "grid")
    private let aspectButton = ToolbarChip(symbol: "aspectratio")
    private let timerButton = ToolbarChip(symbol: "timer")
    private let burstButton = ToolbarChip(symbol: "square.stack.3d.down.right")
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
    private let gridCycle: [PRMGridView.GridType?] = [nil, .ruleOfThirds, .phi, .fibonacci]

    private var torchOn = false

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

    private var timerSetting: TimerSetting = .off
    private var burstEnabled = false

    private var initialPinchZoom: CGFloat = 1.0
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    private var lastDevice: PRMCameraDevice?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationController?.setNavigationBarHidden(true, animated: false)
        modalPresentationCapturesStatusBarAppearance = true

        setupLayout()
        wireGestures()
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await camera.stop() }
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(previewView)
        previewView.snp.makeConstraints { $0.edges.equalToSuperview() }
        previewView.rotation = .rotate90

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
        torchButton.onTap = { [weak self] in self?.toggleTorch() }
        gridButton.onTap = { [weak self] in self?.cycleGrid() }
        aspectButton.onTap = { [weak self] in self?.cycleAspect() }
        timerButton.onTap = { [weak self] in self?.cycleTimer() }
        burstButton.onTap = { [weak self] in self?.toggleBurst() }
        settingsButton.onTap = { [weak self] in self?.toggleDrawer() }
        topBar.addArrangedSubview(torchButton)
        topBar.addArrangedSubview(gridButton)
        topBar.addArrangedSubview(aspectButton)
        topBar.addArrangedSubview(timerButton)
        topBar.addArrangedSubview(burstButton)
        topBar.addArrangedSubview(UIView())  // spacer
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

        view.addSubview(modeStrip)
        modeStrip.onSelect = { [weak self] index in
            self?.applyModeFromIndex(index)
        }

        view.addSubview(shutter)
        view.addSubview(switchCameraButton)
        switchCameraButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchCameraButton.tintColor = .white
        switchCameraButton.contentVerticalAlignment = .fill
        switchCameraButton.contentHorizontalAlignment = .fill
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

        modeStrip.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.leading.greaterThanOrEqualToSuperview().offset(16)
            $0.trailing.lessThanOrEqualToSuperview().offset(-16)
            $0.bottom.equalTo(shutter.snp.top).offset(-14)
            $0.height.equalTo(34)
        }

        lensStrip.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(modeStrip.snp.top).offset(-12)
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

        Task { [weak self] in
            guard let self else { return }
            for await state in camera.stateStream() {
                guard !Task.isCancelled else { break }
                updateTelemetry(from: state)
            }
        }

        await camera.start()
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

    // MARK: - Mode strip

    private func populateModeStrip() {
        let device = camera.device
        var modes: [Mode] = [.photo, .live, .portrait, .pano, .video]
        if device?.supportsSlowMotion == true {
            modes.append(.slowMo)
        }
        modes.append(.night)
        modeStrip.setModes(modes.map(\.label))
        modeStrip.selectedIndex = 0
    }

    private func applyModeFromIndex(_ index: Int) {
        let modes: [Mode] = [.photo, .live, .portrait, .pano, .video]
        var all = modes
        if camera.device?.supportsSlowMotion == true { all.append(.slowMo) }
        all.append(.night)
        guard index >= 0, index < all.count else { return }
        mode = all[index]
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

    private func capturePhoto() {
        guard let photoCapture else { return }
        let settings = PRMPhotoSettings()
            .flashMode(torchOn ? .on : .auto)
            .qualityPrioritization(.quality)

        flashOverlay()
        Task {
            do {
                let photo = try await photoCapture.capturePhoto(settings: settings)
                await saveToPhotoLibrary(data: photo.data)
            } catch {
                showToast("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func captureBurst() {
        guard let photoCapture else { return }
        let settings = PRMPhotoSettings()
            .flashMode(torchOn ? .on : .auto)
            .qualityPrioritization(.speed)
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
        let settings = PRMPhotoSettings().flashMode(.off).qualityPrioritization(.quality)
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
        let settings = PRMPhotoSettings().flashMode(.off).qualityPrioritization(.quality)
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
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
            }
            if !silent { showToast("Saved to Photos") }
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func saveLivePhoto(_ live: PRMLivePhoto) async {
        guard await ensurePhotoLibraryAccess() else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                let movieOptions = PHAssetResourceCreationOptions()
                movieOptions.shouldMoveFile = true
                request.addResource(with: .photo, data: live.photo.data, options: photoOptions)
                request.addResource(with: .pairedVideo, fileURL: live.movieURL, options: movieOptions)
            }
            showToast("Saved Live Photo")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
            PRMTempFile.remove(live.movieURL)
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
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: recording.url, options: PHAssetResourceCreationOptions())
            }
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
            mode = .video
            modeStrip.selectedIndex = modeStrip.indexOf(label: Mode.video.label) ?? 0
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

    // MARK: - Top bar actions

    private func toggleTorch() {
        torchOn.toggle()
        torchButton.setSymbol(torchOn ? "bolt.fill" : "bolt.slash.fill", active: torchOn)
        Task { await camera.setTorch(torchOn ? .on(level: 1.0) : .off) }
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

    private func toggleBurst() {
        burstEnabled.toggle()
        burstButton.setActive(burstEnabled)
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
            makeISORow(device: device),
            makeShutterRow(device: device),
        ])
        drawer.appendSection(title: "White Balance", rows: [
            makeWhiteBalanceRow(),
        ])
        drawer.appendSection(title: "Focus", rows: [
            makeFocusRow(),
        ])
        drawer.appendSection(title: "Capture", rows: [
            makeHDRRow(),
            makeLowLightRow(),
            makeStabilizationRow(),
        ])
        drawer.appendSection(title: "Format", rows: [
            makeCodecRow(),
        ])
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
        let slider = UISlider()
        slider.minimumValue = device.isoRange.lowerBound
        slider.maximumValue = device.isoRange.upperBound
        slider.value = camera.state.iso
        let row = PRMSettingsRow(
            symbolName: "camera.aperture",
            title: "ISO",
            valueText: "\(Int(camera.state.iso))",
            content: slider
        )
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
        segmented.selectedSegmentIndex = 1
        let row = PRMSettingsRow(
            symbolName: "doc.zipper",
            title: "Codec",
            valueText: "heic",
            content: segmented
        )
        segmented.addAction(UIAction { [weak row] _ in
            row?.valueText = segmented.selectedSegmentIndex == 0 ? "jpeg" : "heic"
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
        stackView.snp.makeConstraints {
            $0.edges.equalToSuperview()
            $0.height.equalToSuperview()
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
