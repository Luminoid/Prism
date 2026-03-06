import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - CameraExampleViewController

/// Demonstrates live camera preview with filter switching, tap-to-focus,
/// pinch-to-zoom, torch toggle, grid type cycling, PRMCameraDelegate callbacks,
/// session lifecycle events, and filtered photo capture.
final class CameraExampleViewController: UIViewController {
    // MARK: - Properties

    private let sessionManager = PRMCameraSessionManager()
    private let filterPipeline = PRMFilterPipeline()
    private let previewView = PRMPreviewMetalView(frame: .zero)
    private let focusView = PRMCameraFocusView()
    private let captureButton = PRMCameraButton()
    private let gridOverlay = PRMGridOverlayView()

    private let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.PrismExample.VideoDataOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    private var renderers: [PRMBasicFilterRenderer] = []
    private var currentFilterIndex = -1 // -1 = no filter (pass-through)
    private var initialZoomFactor: CGFloat = 1.0

    private let statusLabel = UILabel()
    private let cameraInfoLabel = UILabel()

    /// Cycles through grid types: thirds → phi → crosshair → off
    private let gridTypes: [PRMGridOverlayView.GridType?] = [
        .ruleOfThirds, .phi, .crosshair, nil,
    ]
    private var gridTypeIndex = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Live Camera"
        view.backgroundColor = .black
        setupUI()
        setupFilters()
        setupCamera()
        setupSessionCallbacks()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let sm = sessionManager
        sm.sessionQueue.async { sm.startSession() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let sm = sessionManager
        sm.sessionQueue.async { sm.stopSession() }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(previewView)
        previewView.snp.makeConstraints { $0.edges.equalToSuperview() }

        // Grid overlay
        view.addSubview(gridOverlay)
        gridOverlay.snp.makeConstraints { $0.edges.equalToSuperview() }

        // Filter segmented control (scrollable — 19 segments won't fit at fixed width)
        var filterNames = ["None"]
        filterNames.append(contentsOf: ExampleFilterCatalog.all.map(\.name))
        let segmented = ScrollableSegmentedControl(items: filterNames)
        segmented.selectedSegmentIndex = 0
        segmented.apportionsSegmentWidthsByContent = true
        segmented.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        segmented.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        let filterScrollView = ControlScrollView()
        filterScrollView.showsHorizontalScrollIndicator = false
        filterScrollView.delaysContentTouches = false
        filterScrollView.canCancelContentTouches = true
        filterScrollView.addSubview(segmented)
        segmented.snp.makeConstraints {
            $0.edges.equalToSuperview()
            $0.height.equalToSuperview()
        }

        view.addSubview(filterScrollView)
        filterScrollView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.height.equalTo(32)
        }

        // Camera delegate status label
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 6
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(filterScrollView.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // Camera / lens info label
        cameraInfoLabel.numberOfLines = 0
        cameraInfoLabel.textColor = .white
        cameraInfoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cameraInfoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cameraInfoLabel.textAlignment = .center
        cameraInfoLabel.layer.cornerRadius = 6
        cameraInfoLabel.clipsToBounds = true
        view.addSubview(cameraInfoLabel)
        cameraInfoLabel.snp.makeConstraints {
            $0.top.equalTo(statusLabel.snp.bottom).offset(4)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // Toolbar: torch toggle + grid cycle
        let torchButton = UIButton(type: .system)
        torchButton.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        torchButton.tintColor = .white
        torchButton.addTarget(self, action: #selector(toggleTorch(_:)), for: .touchUpInside)

        let gridButton = UIButton(type: .system)
        gridButton.setImage(UIImage(systemName: "grid"), for: .normal)
        gridButton.tintColor = .white
        gridButton.addTarget(self, action: #selector(cycleGrid(_:)), for: .touchUpInside)

        let toolStack = UIStackView(arrangedSubviews: [torchButton, gridButton])
        toolStack.axis = .horizontal
        toolStack.spacing = 20
        view.addSubview(toolStack)
        toolStack.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(20)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-28)
        }

        // Capture button — captures photo and saves to library
        view.addSubview(captureButton)
        captureButton.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
            $0.size.equalTo(CGSize(width: 72, height: 72))
        }
        captureButton.onTap = { [weak self] in
            self?.handleCapture()
        }

        // Camera switch button
        let switchButton = UIButton(type: .system)
        switchButton.setImage(UIImage(systemName: "camera.rotate"), for: .normal)
        switchButton.tintColor = .white
        switchButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        view.addSubview(switchButton)
        switchButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().offset(-20)
            $0.centerY.equalTo(captureButton)
            $0.size.equalTo(CGSize(width: 44, height: 44))
        }

        // Tap to focus
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        previewView.addGestureRecognizer(tapGesture)

        // Pinch to zoom
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchToZoom(_:)))
        previewView.addGestureRecognizer(pinchGesture)
    }

    private func setupFilters() {
        renderers = ExampleFilterCatalog.all.map { $0.makeRenderer() }
    }

    private func setupCamera() {
        let preview = previewView
        let sm = sessionManager
        let pipeline = filterPipeline
        let outputQueue = dataOutputQueue

        sm.cameraDelegate = self

        pipeline.onFrame = { pixelBuffer, _ in
            preview.pixelBuffer = pixelBuffer
            preview.requestDraw()
        }

        sm.sessionQueue.async { [weak self] in
            sm.checkAuthorization()
            sm.configureSession(
                with: PRMCameraConfiguration(),
                videoDataOutputDelegate: pipeline,
                videoDataOutputQueue: outputQueue,
            )
            pipeline.isRenderingEnabled = true

            // Show camera/lens info
            if let device = sm.videoDevice {
                let lenses = PRMZoomHelper.lensInfos(for: device)
                let lensDescriptions = lenses.map { "\($0.focalLength) mm (\(String(format: "%.1f", $0.displayZoomFactor))×)" }
                let cameraInfo = "\(device.localizedName)\n\(lensDescriptions.joined(separator: ", "))"
                DispatchQueue.main.async {
                    self?.cameraInfoLabel.text = cameraInfo
                }
            }

            DispatchQueue.main.async {
                preview.rotation = .rotate90Degrees
            }
        }
    }

    private func setupSessionCallbacks() {
        sessionManager.onSessionRunningChanged = { [weak self] isRunning in
            DispatchQueue.main.async {
                self?.statusLabel.text = "Session: \(isRunning ? "Running" : "Stopped")"
            }
        }

        sessionManager.onSessionInterrupted = { [weak self] _ in
            DispatchQueue.main.async {
                CaptureHelper.showToast("Session interrupted", in: self?.view ?? UIView())
            }
        }

        sessionManager.onSessionInterruptionEnded = { [weak self] in
            DispatchQueue.main.async {
                CaptureHelper.showToast("Session resumed", in: self?.view ?? UIView())
            }
        }

        sessionManager.onSessionRuntimeError = { [weak self] error in
            DispatchQueue.main.async {
                CaptureHelper.showToast("Error: \(error.localizedDescription)", in: self?.view ?? UIView())
            }
        }
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: UISegmentedControl) {
        let index = sender.selectedSegmentIndex - 1 // -1 = None
        currentFilterIndex = index

        dataOutputQueue.sync {
            filterPipeline.isRenderingEnabled = false
            if index >= 0, index < renderers.count {
                filterPipeline.activeRenderer = renderers[index]
            } else {
                filterPipeline.activeRenderer = nil
            }
            filterPipeline.isRenderingEnabled = true
        }
    }

    @objc private func switchCamera() {
        let sm = sessionManager
        let pipeline = filterPipeline
        let outputQueue = dataOutputQueue
        let preview = previewView

        sm.sessionQueue.async {
            let currentPosition = sm.videoDevice?.position ?? .back
            let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back

            outputQueue.sync {
                pipeline.isRenderingEnabled = false
                pipeline.activeRenderer?.reset()
            }

            sm.switchCamera(to: newPosition)
            preview.mirroring = newPosition == .front

            outputQueue.sync {
                pipeline.isRenderingEnabled = true
            }
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: previewView)
        let texturePoint = previewView.texturePoint(fromViewPoint: viewPoint)

        focusView.show(at: viewPoint, in: previewView)

        sessionManager.focus(
            with: .autoFocus,
            exposureMode: .autoExpose,
            at: texturePoint,
            monitorSubjectAreaChange: true,
        )
    }

    @objc private func handlePinchToZoom(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            if let device = sessionManager.videoDevice {
                initialZoomFactor = device.videoZoomFactor
            }
        case .changed:
            let newFactor = initialZoomFactor * gesture.scale
            sessionManager.setZoom(factor: newFactor)
        default:
            break
        }
    }

    @objc private func toggleTorch(_ sender: UIButton) {
        guard let device = sessionManager.videoDevice,
              PRMTorchHelper.isTorchAvailable(on: device) else { return }

        let isActive = PRMTorchHelper.isTorchActive(on: device)
        let newMode: PRMTorchHelper.TorchMode = isActive ? .off : .on(level: 1.0)
        sessionManager.setTorch(mode: newMode)

        let imageName = isActive ? "flashlight.off.fill" : "flashlight.on.fill"
        sender.setImage(UIImage(systemName: imageName), for: .normal)
    }

    @objc private func cycleGrid(_ sender: UIButton) {
        gridTypeIndex = (gridTypeIndex + 1) % gridTypes.count

        if let type = gridTypes[gridTypeIndex] {
            gridOverlay.gridType = type
            gridOverlay.isGridVisible = true
            sender.tintColor = .systemYellow
        } else {
            gridOverlay.isGridVisible = false
            sender.tintColor = .white
        }
    }

    // MARK: - Capture

    private func handleCapture() {
        let filter: (any PRMCameraFilter)? = if currentFilterIndex >= 0,
                                                currentFilterIndex < ExampleFilterCatalog.all.count {
            ExampleFilterCatalog.all[currentFilterIndex].makeFilter()
        } else {
            nil
        }

        CaptureHelper.captureAndSave(
            sessionManager: sessionManager,
            filter: filter,
            willCapture: { [weak self] in
                DispatchQueue.main.async {
                    self?.previewView.alpha = 0
                    UIView.animate(withDuration: 0.25) {
                        self?.previewView.alpha = 1
                    }
                }
            },
            completion: { [weak self] message in
                guard let self else { return }
                CaptureHelper.showToast(message, in: view)
            },
        )
    }
}

// MARK: - PRMCameraDelegate

extension CameraExampleViewController: PRMCameraDelegate {
    nonisolated func didUpdateFocusAndExposure(
        at point: CGPoint,
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "Focus: \(focusMode.description) at (\(String(format: "%.2f", point.x)), \(String(format: "%.2f", point.y)))\nExposure: \(exposureMode.description)"
        }
    }

    nonisolated func didUpdateTorch(isOn: Bool, level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "Torch: \(isOn ? "On (\(String(format: "%.0f%%", level * 100)))" : "Off")"
        }
    }

    nonisolated func didUpdateExposure(bias: Float, mode: AVCaptureDevice.ExposureMode) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "Exposure: \(mode.description), bias \(String(format: "%+.1f", bias))"
        }
    }

    nonisolated func didUpdateWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "White Balance: \(mode.description)"
        }
    }
}

// MARK: - AVCaptureDevice Mode Descriptions

private extension AVCaptureDevice.FocusMode {
    var description: String {
        switch self {
        case .locked: "Locked"
        case .autoFocus: "Auto"
        case .continuousAutoFocus: "Continuous"
        @unknown default: "Unknown"
        }
    }
}

private extension AVCaptureDevice.ExposureMode {
    var description: String {
        switch self {
        case .locked: "Locked"
        case .autoExpose: "Auto"
        case .continuousAutoExposure: "Continuous"
        case .custom: "Custom"
        @unknown default: "Unknown"
        }
    }
}

private extension AVCaptureDevice.WhiteBalanceMode {
    var description: String {
        switch self {
        case .locked: "Locked"
        case .autoWhiteBalance: "Auto"
        case .continuousAutoWhiteBalance: "Continuous"
        @unknown default: "Unknown"
        }
    }
}
