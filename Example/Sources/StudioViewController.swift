@preconcurrency import AVFoundation
import Photos
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - StudioViewController

/// A DSLR-style camera app: live preview, focal-length lens picker, telemetry strip,
/// photo / video / slow-mo modes, tap-to-focus, pinch-to-zoom, drag-to-bias-exposure,
/// hardware capture controls.
///
/// Exercises the full PrismCore + PrismUI surface in one screen.
@MainActor
final class StudioViewController: UIViewController {
    // MARK: - Camera

    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    /// `PRMRenderContext()` only fails when the device has no Metal support, which is
    /// terminal for a Metal-backed preview — no graceful fallback is possible.
    /// The old code re-tried `MTLCreateSystemDefaultDevice()` twice with force-unwraps,
    /// which both crashes harder and creates two devices on the rare success path.
    private let renderContext: PRMRenderContext = {
        guard let context = PRMRenderContext() else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var previewView = PRMPreviewView(context: renderContext)
    private var photoCapture: PRMPhotoCapture?
    private var videoRecorder: PRMVideoRecorder?

    // MARK: - UI

    private let topBar = UIStackView()
    private let telemetryLabel = PaddedLabel()
    private let lensStrip = UIStackView()
    private let modeStrip = UISegmentedControl(items: ["PHOTO", "VIDEO", "SLO-MO"])
    private let shutter = PRMShutterButton()
    private let switchCameraButton = UIButton(type: .system)
    private let gridOverlay = PRMGridView()
    private let aspectMask = PRMAspectRatioMaskView()
    private let levelIndicator = PRMLevelIndicatorView()
    private let focusIndicator = PRMFocusIndicatorView()
    private let recordingTimerLabel = PaddedLabel()
    private let torchButton = ToolbarChip(symbol: "bolt.slash.fill")
    private let gridButton = ToolbarChip(symbol: "grid")
    private let aspectButton = ToolbarChip(symbol: "aspectratio")

    // MARK: - State

    private enum Mode: Equatable {
        case photo, video, slowMo
    }

    private var mode: Mode = .photo {
        didSet { applyModeChange() }
    }

    private var aspectIndex = 0
    private let aspectCycle: [PRMAspectRatioMaskView.AspectRatio] = [.full, .ratio4x3, .ratio16x9, .ratio1x1]

    private var gridIndex = 0
    private let gridCycle: [PRMGridView.GridType?] = [nil, .ruleOfThirds, .phi, .fibonacci]

    private var torchOn = false

    private var initialPinchZoom: CGFloat = 1.0
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

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
        topBar.addArrangedSubview(torchButton)
        topBar.addArrangedSubview(gridButton)
        topBar.addArrangedSubview(aspectButton)
        topBar.addArrangedSubview(UIView())  // spacer

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

        let modeContainer = UIView()
        view.addSubview(modeContainer)
        modeStrip.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor.white,
        ], for: .normal)
        modeStrip.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
        ], for: .selected)
        modeStrip.selectedSegmentTintColor = .systemYellow
        modeStrip.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        modeStrip.selectedSegmentIndex = 0
        modeStrip.addAction(UIAction { [weak self] _ in self?.applyModeFromSegmented() }, for: .valueChanged)
        modeContainer.addSubview(modeStrip)
        modeStrip.snp.makeConstraints { $0.edges.equalToSuperview() }

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

        modeContainer.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(shutter.snp.top).offset(-14)
            $0.height.equalTo(32)
            $0.width.greaterThanOrEqualTo(220)
        }

        lensStrip.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(modeContainer.snp.top).offset(-12)
            $0.height.equalTo(36)
        }

        telemetryLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(lensStrip.snp.top).offset(-12)
            $0.height.equalTo(26)
        }

        view.addSubview(focusIndicator)  // top-most for visibility
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
        // Ensure permissions first.
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        if PRMPermissions.microphoneStatus() == .notDetermined {
            _ = await PRMPermissions.requestMicrophoneAccess()
        }

        do {
            var config = PRMCameraConfiguration()
            config.includesMovieFileOutput = true
            try await camera.configure(config)
        } catch {
            showAlert(title: "Cannot start camera", message: error.localizedDescription)
            return
        }

        // Wire pipeline → preview.
        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.previewView.update(frame.pixelBuffer)
        }

        // Wire photo + video helpers from the actor.
        await PRMCameraActor.shared.run {
            if let photoOutput = await self.camera.session.photoOutput {
                let capture = PRMPhotoCapture(output: photoOutput)
                await MainActor.run { self.photoCapture = capture }
            }
            if let movieOutput = await self.camera.session.movieFileOutput {
                let recorder = PRMVideoRecorder(output: movieOutput)
                await MainActor.run { self.videoRecorder = recorder }
            }
        }

        // Build lens strip.
        rebuildLensStrip()

        // Stream state for telemetry.
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

    // MARK: - Mode

    private func applyModeFromSegmented() {
        switch modeStrip.selectedSegmentIndex {
        case 0: mode = .photo
        case 1: mode = .video
        case 2: mode = .slowMo
        default: mode = .photo
        }
    }

    private func applyModeChange() {
        Task {
            switch mode {
            case .photo:
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

    private func saveToPhotoLibrary(data: Data) async {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if granted != .authorized, granted != .limited {
                showToast("Photo library access denied")
                return
            }
        case .denied, .restricted:
            showToast("Photo library access denied")
            return
        default:
            break
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
            }
            showToast("Saved to Photos")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
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
        switch mode {
        case .photo:
            capturePhoto()
        case .video, .slowMo:
            if recordingStartedAt == nil {
                startRecording()
            } else {
                stopRecording()
            }
        }
    }

    private func handleShutterLongPressBegan() {
        if mode == .photo {
            modeStrip.selectedSegmentIndex = 1
            mode = .video
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

    // MARK: - Top bar

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
        // Vertical drag: ±2 EV with full-screen-height swing.
        guard gesture.state == .changed else { return }
        let translation = gesture.translation(in: view).y / max(view.bounds.height / 2, 1)
        let bias = Float(-translation * 2)
        Task { await camera.setExposureBias(bias) }
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
        telemetryLabel.text = [zoom, iso, shutter, ev, temp, fps]
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
    required init?(coder: NSCoder) {
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
    required init?(coder: NSCoder) {
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
    required init?(coder: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    @objc private func handleTap() {
        onTap?()
    }
}
