import AVFoundation
import CoreMedia
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - DeviceControlsViewController

/// Demonstrates ALL 6 device control helpers with interactive sliders and real-time readouts:
/// `PRMZoomHelper`, `PRMTorchHelper`, `PRMExposureHelper`, `PRMWhiteBalanceHelper`,
/// `PRMStabilizationHelper`, `PRMFrameRateHelper`.
final class DeviceControlsViewController: UIViewController {
    // MARK: - Properties

    private let sessionManager = PRMCameraSessionManager()
    private let filterPipeline = PRMFilterPipeline()
    private let previewView = PRMPreviewMetalView(frame: .zero)
    private let captureButton = PRMCameraButton()

    private let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.PrismExample.DeviceControlOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    // Zoom
    private let zoomSlider = UISlider()
    private let zoomLabel = UILabel()
    private let switchOverLabel = UILabel()
    private let lensButtonStack = UIStackView()

    // Torch
    private let torchSegmented = UISegmentedControl(items: ["Off", "On", "Auto"])
    private let torchLevelSlider = UISlider()
    private let torchLabel = UILabel()

    // Exposure
    private let exposureSegmented = UISegmentedControl(items: ["Auto", "Locked", "Custom"])
    private let evBiasSlider = UISlider()
    private let evLabel = UILabel()
    private let isoSlider = UISlider()
    private let isoLabel = UILabel()

    // White Balance
    private let wbSegmented = UISegmentedControl(items: ["Auto", "Continuous", "Locked"])
    private let presetSegmented = UISegmentedControl(
        items: PRMWhiteBalanceHelper.Preset.allCases.map { "\(Int($0.temperature))K" },
    )
    private let tempSlider = UISlider()
    private let tintSlider = UISlider()
    private let wbLabel = UILabel()

    // Stabilization
    private let stabSegmented = UISegmentedControl(items: ["Off", "Standard", "Cinematic", "Auto"])
    private let stabLabel = UILabel()

    // Frame Rate
    private let fpsSlider = UISlider()
    private let fpsLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Device Controls"
        view.backgroundColor = .black
        setupUI()
        setupCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let sm = sessionManager
        sm.sessionQueue.async {
            sm.startSession()
            DispatchQueue.main.async { [weak self] in
                self?.populateDeviceInfo()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let sm = sessionManager
        sm.sessionQueue.async { sm.stopSession() }
    }

    // MARK: - Setup

    private func setupUI() {
        // Preview (top 40%)
        view.addSubview(previewView)
        previewView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.4)
        }

        // Capture button on preview
        view.addSubview(captureButton)
        captureButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().offset(-16)
            $0.bottom.equalTo(previewView).offset(-12)
            $0.size.equalTo(CGSize(width: 56, height: 56))
        }
        captureButton.buttonSize = 56
        captureButton.onTap = { [weak self] in self?.handleCapture() }

        // Scrollable controls (bottom 60%)
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .systemBackground
        view.addSubview(scrollView)
        scrollView.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom)
            $0.leading.trailing.bottom.equalToSuperview()
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview()
            $0.width.equalToSuperview()
        }

        stack.addArrangedSubview(makeZoomSection())
        stack.addArrangedSubview(makeTorchSection())
        stack.addArrangedSubview(makeExposureSection())
        stack.addArrangedSubview(makeWhiteBalanceSection())
        stack.addArrangedSubview(makeStabilizationSection())
        stack.addArrangedSubview(makeFrameRateSection())
    }

    private func setupCamera() {
        let preview = previewView
        let pipeline = filterPipeline
        let sm = sessionManager
        let outputQueue = dataOutputQueue

        pipeline.onFrame = { pixelBuffer, _ in
            preview.pixelBuffer = pixelBuffer
            preview.requestDraw()
        }

        sm.sessionQueue.async {
            sm.checkAuthorization()
            sm.configureSession(
                with: PRMCameraConfiguration(),
                videoDataOutputDelegate: pipeline,
                videoDataOutputQueue: outputQueue,
            )
            pipeline.isRenderingEnabled = true
            DispatchQueue.main.async { preview.rotation = .rotate90Degrees }
        }
    }

    // MARK: - Section Builders

    private func makeZoomSection() -> UIView {
        configureInfoLabel(zoomLabel)
        configureInfoLabel(switchOverLabel)
        switchOverLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        zoomSlider.addTarget(self, action: #selector(zoomChanged), for: .valueChanged)

        // Lens switch buttons (populated in populateDeviceInfo when device is available)
        lensButtonStack.axis = .horizontal
        lensButtonStack.spacing = 12
        lensButtonStack.distribution = .fillEqually

        let rampButton = UIButton(type: .system)
        rampButton.setTitle("Ramp to Tele", for: .normal)
        rampButton.addTarget(self, action: #selector(rampZoom), for: .touchUpInside)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel Ramp", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelZoomRamp), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [rampButton, cancelButton])
        buttonRow.spacing = 16

        return makeSection(title: "Zoom", views: [lensButtonStack, zoomSlider, zoomLabel, switchOverLabel, buttonRow])
    }

    private func makeTorchSection() -> UIView {
        configureInfoLabel(torchLabel)
        torchSegmented.selectedSegmentIndex = 0
        torchSegmented.addTarget(self, action: #selector(torchModeChanged), for: .valueChanged)
        torchLevelSlider.minimumValue = 0.0
        torchLevelSlider.maximumValue = 1.0
        torchLevelSlider.value = 1.0
        torchLevelSlider.isEnabled = false
        torchLevelSlider.addTarget(self, action: #selector(torchLevelChanged), for: .valueChanged)

        return makeSection(title: "Torch", views: [torchSegmented, torchLevelSlider, torchLabel])
    }

    private func makeExposureSection() -> UIView {
        configureInfoLabel(evLabel)
        configureInfoLabel(isoLabel)
        exposureSegmented.selectedSegmentIndex = 0
        exposureSegmented.addTarget(self, action: #selector(exposureModeChanged), for: .valueChanged)
        evBiasSlider.addTarget(self, action: #selector(evBiasChanged), for: .valueChanged)
        isoSlider.addTarget(self, action: #selector(isoChanged), for: .valueChanged)
        isoSlider.isEnabled = false

        return makeSection(title: "Exposure", views: [exposureSegmented, evBiasSlider, evLabel, isoSlider, isoLabel])
    }

    private func makeWhiteBalanceSection() -> UIView {
        configureInfoLabel(wbLabel)
        wbSegmented.selectedSegmentIndex = 0
        wbSegmented.addTarget(self, action: #selector(wbModeChanged), for: .valueChanged)
        presetSegmented.selectedSegmentIndex = UISegmentedControl.noSegment
        presetSegmented.addTarget(self, action: #selector(wbPresetChanged), for: .valueChanged)
        presetSegmented.isEnabled = false

        tempSlider.minimumValue = 2000
        tempSlider.maximumValue = 10000
        tempSlider.value = 5500
        tempSlider.isEnabled = false
        tempSlider.addTarget(self, action: #selector(wbCustomChanged), for: .valueChanged)

        tintSlider.minimumValue = -150
        tintSlider.maximumValue = 150
        tintSlider.value = 0
        tintSlider.isEnabled = false
        tintSlider.addTarget(self, action: #selector(wbCustomChanged), for: .valueChanged)

        let tempLabel = UILabel()
        tempLabel.text = "Temperature"
        tempLabel.font = .systemFont(ofSize: 12)
        tempLabel.textColor = .secondaryLabel

        let tintLabel = UILabel()
        tintLabel.text = "Tint"
        tintLabel.font = .systemFont(ofSize: 12)
        tintLabel.textColor = .secondaryLabel

        return makeSection(
            title: "White Balance",
            views: [wbSegmented, presetSegmented, tempLabel, tempSlider, tintLabel, tintSlider, wbLabel],
        )
    }

    private func makeStabilizationSection() -> UIView {
        configureInfoLabel(stabLabel)
        stabSegmented.selectedSegmentIndex = 0
        stabSegmented.addTarget(self, action: #selector(stabilizationChanged), for: .valueChanged)

        return makeSection(title: "Stabilization", views: [stabSegmented, stabLabel])
    }

    private func makeFrameRateSection() -> UIView {
        configureInfoLabel(fpsLabel)
        fpsSlider.addTarget(self, action: #selector(fpsChanged), for: .valueChanged)

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Reset to Default", for: .normal)
        resetButton.addTarget(self, action: #selector(resetFrameRate), for: .touchUpInside)

        return makeSection(title: "Frame Rate", views: [fpsSlider, fpsLabel, resetButton])
    }

    private func makeSection(title: String, views: [UIView]) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 10

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [titleLabel] + views)
        stack.axis = .vertical
        stack.spacing = 8

        container.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }

        return container
    }

    private func configureInfoLabel(_ label: UILabel) {
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
    }

    // MARK: - Populate Device Info

    private func populateDeviceInfo() {
        guard let device = sessionManager.videoDevice else { return }

        // Zoom
        let minZoom = Float(PRMZoomHelper.minZoomFactor(for: device))
        let maxZoom = min(Float(PRMZoomHelper.maxZoomFactor(for: device)), 15.0) // Cap slider at 15×
        zoomSlider.minimumValue = minZoom
        zoomSlider.maximumValue = maxZoom
        zoomSlider.value = Float(PRMZoomHelper.currentZoomFactor(for: device))
        let switchOvers = PRMZoomHelper.switchOverZoomFactors(for: device)
        let wideFactor = switchOvers.first ?? 1.0
        switchOverLabel.text = "Switch-over: \(switchOvers.map { String(format: "%.1f×", $0 / wideFactor) }.joined(separator: ", "))"

        // Lens switch buttons — show 35mm-equivalent focal lengths (e.g., "13 mm", "24 mm", "120 mm")
        lensButtonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lenses = PRMZoomHelper.lensInfos(for: device)
        for lens in lenses {
            let button = UIButton(type: .system)
            button.setTitle("\(lens.focalLength) mm (\(String(format: "%.1f", lens.displayZoomFactor))×)", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.layer.cornerRadius = 6
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.systemBlue.cgColor
            button.tag = Int(lens.zoomFactor * 100) // encode factor as tag
            button.addTarget(self, action: #selector(lensSwitchTapped(_:)), for: .touchUpInside)
            button.snp.makeConstraints { $0.height.equalTo(36) }
            lensButtonStack.addArrangedSubview(button)
        }

        updateZoomLabel()

        // Exposure
        let biasRange = PRMExposureHelper.exposureBiasRange(for: device)
        evBiasSlider.minimumValue = biasRange.lowerBound
        evBiasSlider.maximumValue = biasRange.upperBound
        evBiasSlider.value = PRMExposureHelper.currentExposureTargetBias(for: device)
        let isoRange = PRMExposureHelper.isoRange(for: device)
        isoSlider.minimumValue = isoRange.lowerBound
        isoSlider.maximumValue = isoRange.upperBound
        isoSlider.value = PRMExposureHelper.currentISO(for: device)
        updateExposureLabels()

        // White Balance
        let current = PRMWhiteBalanceHelper.currentTemperatureAndTint(for: device)
        tempSlider.value = current.temperature
        tintSlider.value = current.tint
        updateWBLabel()

        // Frame Rate
        let maxFPS = Float(PRMFrameRateHelper.maxSupportedFrameRate(for: device))
        let currentFPS = PRMFrameRateHelper.currentFrameRate(for: device) ?? 30
        fpsSlider.minimumValue = 1
        fpsSlider.maximumValue = min(maxFPS, 240)
        fpsSlider.value = Float(currentFPS)
        updateFPSLabel(fps: currentFPS)

        // Stabilization
        updateStabilizationLabel()

        // Torch
        updateTorchLabel()
    }

    // MARK: - Actions — Zoom

    @objc private func zoomChanged() {
        let factor = CGFloat(zoomSlider.value)
        sessionManager.setZoom(factor: factor)
        updateZoomLabel(overrideZoom: factor)
    }

    @objc private func rampZoom() {
        guard let device = sessionManager.videoDevice else { return }
        let lenses = PRMZoomHelper.lensInfos(for: device)
        // Ramp to the telephoto (last) lens, or max zoom if no lenses
        let target = lenses.last?.zoomFactor ?? PRMZoomHelper.maxZoomFactor(for: device)
        sessionManager.rampZoom(to: target, withRate: 1.0)
    }

    @objc private func cancelZoomRamp() {
        let sm = sessionManager
        sm.sessionQueue.async {
            guard let device = sm.videoDevice else { return }
            try? PRMZoomHelper.cancelZoomRamp(on: device)
        }
    }

    @objc private func lensSwitchTapped(_ sender: UIButton) {
        let factor = CGFloat(sender.tag) / 100.0
        sessionManager.setZoom(factor: factor)
        zoomSlider.value = Float(factor)
        updateZoomLabel(overrideZoom: factor)
    }

    private func updateZoomLabel(overrideZoom: CGFloat? = nil) {
        guard let device = sessionManager.videoDevice else { return }
        let current = overrideZoom ?? PRMZoomHelper.currentZoomFactor(for: device)
        let switchOvers = PRMZoomHelper.switchOverZoomFactors(for: device)
        let wideFactor = switchOvers.first ?? 1.0
        zoomLabel.text = String(format: "%.1f×", current / wideFactor)
    }

    // MARK: - Actions — Torch

    @objc private func torchModeChanged() {
        let mode: PRMTorchHelper.TorchMode
        switch torchSegmented.selectedSegmentIndex {
        case 1:
            mode = .on(level: torchLevelSlider.value)
            torchLevelSlider.isEnabled = true
        case 2:
            mode = .auto
            torchLevelSlider.isEnabled = false
        default:
            mode = .off
            torchLevelSlider.isEnabled = false
        }
        sessionManager.setTorch(mode: mode)
        updateTorchLabel()
    }

    @objc private func torchLevelChanged() {
        sessionManager.setTorch(mode: .on(level: torchLevelSlider.value))
        updateTorchLabel()
    }

    private func updateTorchLabel() {
        guard let device = sessionManager.videoDevice else { return }
        let available = PRMTorchHelper.isTorchAvailable(on: device)
        let active = PRMTorchHelper.isTorchActive(on: device)
        let level = PRMTorchHelper.currentTorchLevel(on: device)
        torchLabel.text = "Available: \(available) | Active: \(active) | Level: \(String(format: "%.2f", level))"
    }

    // MARK: - Actions — Exposure

    @objc private func exposureModeChanged() {
        let sm = sessionManager
        let index = exposureSegmented.selectedSegmentIndex
        isoSlider.isEnabled = index == 2 // Custom

        sm.sessionQueue.async {
            guard let device = sm.videoDevice else { return }
            switch index {
            case 0: try? PRMExposureHelper.setExposureMode(.continuousAutoExposure, on: device)
            case 1: try? PRMExposureHelper.setExposureMode(.locked, on: device)
            case 2: try? PRMExposureHelper.setExposureMode(.custom, on: device)
            default: break
            }
        }
    }

    @objc private func evBiasChanged() {
        sessionManager.setExposureBias(evBiasSlider.value)
        updateExposureLabels()
    }

    @objc private func isoChanged() {
        let sm = sessionManager
        let iso = isoSlider.value
        sm.sessionQueue.async {
            guard let device = sm.videoDevice else { return }
            let duration = device.exposureDuration
            try? PRMExposureHelper.setCustomExposure(duration: duration, iso: iso, on: device)
        }
        updateExposureLabels()
    }

    private func updateExposureLabels() {
        guard let device = sessionManager.videoDevice else { return }
        let bias = PRMExposureHelper.currentExposureTargetBias(for: device)
        let iso = PRMExposureHelper.currentISO(for: device)
        let duration = PRMExposureHelper.currentExposureDuration(for: device)
        let seconds = CMTimeGetSeconds(duration)
        let durationStr = seconds > 0 ? "1/\(Int(1.0 / seconds))" : "N/A"
        evLabel.text = String(format: "EV: %.1f | ISO: %.0f | Duration: %@", bias, iso, durationStr)
        isoLabel.text = String(
            format: "ISO range: %.0f – %.0f",
            PRMExposureHelper.isoRange(for: device).lowerBound,
            PRMExposureHelper.isoRange(for: device).upperBound,
        )
    }

    // MARK: - Actions — White Balance

    @objc private func wbModeChanged() {
        let index = wbSegmented.selectedSegmentIndex
        let locked = index == 2
        presetSegmented.isEnabled = locked
        tempSlider.isEnabled = locked
        tintSlider.isEnabled = locked

        switch index {
        case 0: sessionManager.setWhiteBalance(mode: .autoWhiteBalance)
        case 1: sessionManager.setWhiteBalance(mode: .continuousAutoWhiteBalance)
        case 2: sessionManager.setWhiteBalance(mode: .locked)
        default: break
        }
        updateWBLabel()
    }

    @objc private func wbPresetChanged() {
        let presets = PRMWhiteBalanceHelper.Preset.allCases
        guard presetSegmented.selectedSegmentIndex < presets.count else { return }
        let preset = presets[presetSegmented.selectedSegmentIndex]
        let sm = sessionManager
        sm.sessionQueue.async {
            guard let device = sm.videoDevice else { return }
            try? PRMWhiteBalanceHelper.lockWhiteBalance(preset: preset, on: device)
            DispatchQueue.main.async { [weak self] in
                self?.tempSlider.value = preset.temperature
                self?.tintSlider.value = 0
                self?.updateWBLabel()
            }
        }
    }

    @objc private func wbCustomChanged() {
        let tempAndTint = PRMWhiteBalanceHelper.TemperatureAndTint(
            temperature: tempSlider.value,
            tint: tintSlider.value,
        )
        let sm = sessionManager
        sm.sessionQueue.async { [weak self] in
            guard let device = sm.videoDevice else { return }
            try? PRMWhiteBalanceHelper.lockWhiteBalance(temperatureAndTint: tempAndTint, on: device)
            DispatchQueue.main.async {
                self?.updateWBLabel()
            }
        }
    }

    private func updateWBLabel() {
        guard let device = sessionManager.videoDevice else { return }
        let current = PRMWhiteBalanceHelper.currentTemperatureAndTint(for: device)
        let mode = PRMWhiteBalanceHelper.currentWhiteBalanceMode(for: device)
        let modeStr = switch mode {
        case .locked: "Locked"
        case .autoWhiteBalance: "Auto"
        case .continuousAutoWhiteBalance: "Continuous"
        @unknown default: "Unknown"
        }
        wbLabel.text = String(format: "Mode: %@ | Temp: %.0fK | Tint: %.1f", modeStr, current.temperature, current.tint)
    }

    // MARK: - Actions — Stabilization

    @objc private func stabilizationChanged() {
        let modes: [AVCaptureVideoStabilizationMode] = [.off, .standard, .cinematic, .auto]
        sessionManager.setStabilizationMode(modes[stabSegmented.selectedSegmentIndex])
        // Delay label update so the mode has time to apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateStabilizationLabel()
        }
    }

    private func updateStabilizationLabel() {
        guard let connection = sessionManager.videoDataOutput?.connection(with: .video) else {
            stabLabel.text = "No video connection"
            return
        }
        let supported = PRMStabilizationHelper.isStabilizationSupported(on: connection)
        let active = PRMStabilizationHelper.activeStabilizationMode(on: connection)
        let preferred = PRMStabilizationHelper.preferredStabilizationMode(on: connection)
        stabLabel.text = "Supported: \(supported) | Active: \(stabModeName(active)) | Preferred: \(stabModeName(preferred))"
    }

    private func stabModeName(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        case .auto: "Auto"
        case .cinematicExtended: "Cinematic Ext"
        case .previewOptimized: "Preview"
        @unknown default: "Unknown"
        }
    }

    // MARK: - Actions — Frame Rate

    @objc private func fpsChanged() {
        let fps = Float64(fpsSlider.value).rounded()
        sessionManager.setFrameRate(fps)
        updateFPSLabel(fps: fps)
    }

    @objc private func resetFrameRate() {
        let sm = sessionManager
        sm.sessionQueue.async {
            guard let device = sm.videoDevice else { return }
            try? PRMFrameRateHelper.resetToDefaultFrameRate(on: device)
            let actualFPS = PRMFrameRateHelper.currentFrameRate(for: device) ?? 30
            DispatchQueue.main.async { [weak self] in
                self?.fpsSlider.value = Float(actualFPS)
                self?.updateFPSLabel(fps: actualFPS)
            }
        }
    }

    private func updateFPSLabel(fps: Float64) {
        guard let device = sessionManager.videoDevice else { return }
        let maxFPS = PRMFrameRateHelper.maxSupportedFrameRate(for: device)
        let slowMo = PRMFrameRateHelper.supportsSlowMotion(on: device)
        let supports = PRMFrameRateHelper.supportsFrameRate(fps, on: device)
        fpsLabel.text = "\(Int(fps)) fps (supported: \(supports)) | Max: \(Int(maxFPS)) | SlowMo: \(slowMo ? "Yes" : "No")"
    }

    // MARK: - Capture

    private func handleCapture() {
        CaptureHelper.captureAndSave(
            sessionManager: sessionManager,
            filter: nil,
            willCapture: { [weak self] in
                DispatchQueue.main.async {
                    self?.previewView.alpha = 0
                    UIView.animate(withDuration: 0.25) { self?.previewView.alpha = 1 }
                }
            },
            completion: { [weak self] message in
                guard let self else { return }
                CaptureHelper.showToast(message, in: self.view)
            },
        )
    }
}
