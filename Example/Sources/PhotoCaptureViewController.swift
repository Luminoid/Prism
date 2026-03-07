import AVFoundation
import AVKit
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - PhotoCaptureViewController

/// Demonstrates filtered photo capture using PRMPhotoCaptureProcessor,
/// PRMPhotoSettingsBuilder (full API), PRMAspectRatioOverlayView,
/// PRMDepthHelper, and PRMCaptureControlHelper (iOS 17.2+).
final class PhotoCaptureViewController: UIViewController {
    // MARK: - Properties

    private let sessionManager = PRMCameraSessionManager()
    private let filterPipeline = PRMFilterPipeline()
    private let previewView = PRMPreviewMetalView(frame: .zero)
    private let captureButton = PRMCameraButton()
    private let aspectOverlay = PRMAspectRatioOverlayView()

    private let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.PrismExample.PhotoDataOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    private var currentFilter: (any PRMCameraFilter)?
    private var currentFlashMode: AVCaptureDevice.FlashMode = .off
    private var activeProcessor: PRMPhotoCaptureProcessor?

    // Settings panel state
    private var qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .balanced
    private var enableRedEye = false
    private var enableDepth = false
    private var enableStabilization = true
    private var isDepthSupported = false

    private let settingsContainer = UIView()
    private let depthStatusLabel = UILabel()
    private let processingLabel = UILabel()

    private var captureControlInteraction: AnyObject?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Photo Capture"
        view.backgroundColor = .black
        setupUI()
        setupCamera()
        setupCaptureControl()
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

        // Aspect ratio overlay
        view.addSubview(aspectOverlay)
        aspectOverlay.snp.makeConstraints { $0.edges.equalToSuperview() }

        // Filter selector (scrollable — 19 segments won't fit at fixed width)
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

        // Aspect ratio picker
        let ratioSegmented = UISegmentedControl(items: ["Full", "4:3", "16:9", "1:1"])
        ratioSegmented.selectedSegmentIndex = 0
        ratioSegmented.addTarget(self, action: #selector(ratioChanged(_:)), for: .valueChanged)
        ratioSegmented.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        view.addSubview(ratioSegmented)
        ratioSegmented.snp.makeConstraints {
            $0.top.equalTo(filterScrollView.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        // Settings panel (collapsible)
        setupSettingsPanel(below: ratioSegmented)

        // Processing indicator
        processingLabel.text = "Processing..."
        processingLabel.textColor = .systemYellow
        processingLabel.font = .systemFont(ofSize: 14, weight: .medium)
        processingLabel.textAlignment = .center
        processingLabel.isHidden = true
        view.addSubview(processingLabel)
        processingLabel.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-100)
        }

        // Flash mode button
        let flashButton = UIButton(type: .system)
        flashButton.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
        flashButton.tintColor = .white
        flashButton.tag = 100
        flashButton.addTarget(self, action: #selector(toggleFlash(_:)), for: .touchUpInside)
        view.addSubview(flashButton)
        flashButton.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(20)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-28)
            $0.size.equalTo(CGSize(width: 44, height: 44))
        }

        // Capture button
        view.addSubview(captureButton)
        captureButton.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
            $0.size.equalTo(CGSize(width: 72, height: 72))
        }
        captureButton.onTap = { [weak self] in
            self?.capturePhoto()
        }
    }

    private func setupSettingsPanel(below anchor: UIView) {
        settingsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        settingsContainer.layer.cornerRadius = 8
        settingsContainer.clipsToBounds = true
        view.addSubview(settingsContainer)
        settingsContainer.snp.makeConstraints {
            $0.top.equalTo(anchor.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        settingsContainer.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(8)
        }

        // Quality prioritization
        let qualitySegmented = UISegmentedControl(items: ["Speed", "Balanced", "Quality"])
        qualitySegmented.selectedSegmentIndex = 1
        qualitySegmented.addTarget(self, action: #selector(qualityChanged(_:)), for: .valueChanged)
        let qualityRow = makeSettingsRow(label: "Quality", control: qualitySegmented)
        stack.addArrangedSubview(qualityRow)

        // Red-eye reduction
        let redEyeSwitch = UISwitch()
        redEyeSwitch.isOn = false
        redEyeSwitch.addTarget(self, action: #selector(redEyeChanged(_:)), for: .valueChanged)
        let redEyeRow = makeSettingsRow(label: "Red-Eye Reduction", control: redEyeSwitch)
        stack.addArrangedSubview(redEyeRow)

        // Depth data
        let depthSwitch = UISwitch()
        depthSwitch.isOn = false
        depthSwitch.addTarget(self, action: #selector(depthChanged(_:)), for: .valueChanged)
        let depthRow = makeSettingsRow(label: "Depth Data", control: depthSwitch)
        stack.addArrangedSubview(depthRow)

        depthStatusLabel.textColor = .lightGray
        depthStatusLabel.font = .systemFont(ofSize: 11)
        depthStatusLabel.text = "Checking depth support..."
        stack.addArrangedSubview(depthStatusLabel)

        // Auto stabilization
        let stabSwitch = UISwitch()
        stabSwitch.isOn = true
        stabSwitch.addTarget(self, action: #selector(stabilizationChanged(_:)), for: .valueChanged)
        let stabRow = makeSettingsRow(label: "Stabilization", control: stabSwitch)
        stack.addArrangedSubview(stabRow)

        // Toggle button
        let toggleButton = UIButton(type: .system)
        toggleButton.setTitle("Hide Settings", for: .normal)
        toggleButton.tintColor = .white
        toggleButton.addTarget(self, action: #selector(toggleSettings(_:)), for: .touchUpInside)
        view.addSubview(toggleButton)
        toggleButton.snp.makeConstraints {
            $0.top.equalTo(settingsContainer.snp.bottom).offset(4)
            $0.centerX.equalToSuperview()
        }
    }

    private func makeSettingsRow(label text: String, control: UIView) -> UIStackView {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        return row
    }

    private func setupCamera() {
        let preview = previewView
        let sm = sessionManager
        let pipeline = filterPipeline
        let outputQueue = dataOutputQueue

        pipeline.onFrame = { pixelBuffer, _ in
            preview.pixelBuffer = pixelBuffer
            preview.requestDraw()
        }

        sm.sessionQueue.async { [weak self] in
            sm.checkAuthorization()
            sm.configureSession(
                with: PRMCameraConfiguration(includesAudio: false),
                videoDataOutputDelegate: pipeline,
                videoDataOutputQueue: outputQueue,
            )
            pipeline.isRenderingEnabled = true

            // Check depth support
            if let photoOutput = sm.photoOutput {
                let supported = PRMDepthHelper.isDepthCaptureSupported(on: photoOutput)
                DispatchQueue.main.async {
                    self?.isDepthSupported = supported
                    self?.depthStatusLabel.text = supported
                        ? "Depth capture supported"
                        : "Depth capture not supported on this device"
                }
            }

            DispatchQueue.main.async {
                preview.rotation = .rotate90Degrees
            }
        }
    }

    private func setupCaptureControl() {
        if #available(iOS 17.2, *) {
            let helper = PRMCaptureControlHelper()
            helper.onPrimaryAction = { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.capturePhoto() }
            }
            helper.onSecondaryAction = { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.cycleFlash() }
            }
            let interaction = helper.makeInteraction()
            previewView.addInteraction(interaction)
            captureControlInteraction = helper
        }
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: UISegmentedControl) {
        let index = sender.selectedSegmentIndex - 1

        dataOutputQueue.sync {
            filterPipeline.isRenderingEnabled = false
            if index >= 0, index < ExampleFilterCatalog.all.count {
                let renderer = ExampleFilterCatalog.all[index].makeRenderer()
                filterPipeline.activeRenderer = renderer
                currentFilter = ExampleFilterCatalog.all[index].makeFilter()
            } else {
                filterPipeline.activeRenderer = nil
                currentFilter = nil
            }
            filterPipeline.isRenderingEnabled = true
        }
    }

    @objc private func ratioChanged(_ sender: UISegmentedControl) {
        let ratios: [PRMAspectRatioOverlayView.AspectRatio] = [.full, .ratio4x3, .ratio16x9, .ratio1x1]
        aspectOverlay.aspectRatio = ratios[sender.selectedSegmentIndex]
    }

    @objc private func toggleFlash(_ sender: UIButton) {
        cycleFlash()
        updateFlashButton(sender)
    }

    private func cycleFlash() {
        switch currentFlashMode {
        case .off: currentFlashMode = .auto
        case .auto: currentFlashMode = .on
        default: currentFlashMode = .off
        }
        if let button = view.viewWithTag(100) as? UIButton {
            updateFlashButton(button)
        }
    }

    private func updateFlashButton(_ button: UIButton) {
        let imageName = switch currentFlashMode {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        default: "bolt.fill"
        }
        button.setImage(UIImage(systemName: imageName), for: .normal)
    }

    @objc private func qualityChanged(_ sender: UISegmentedControl) {
        let priorities: [AVCapturePhotoOutput.QualityPrioritization] = [.speed, .balanced, .quality]
        qualityPrioritization = priorities[sender.selectedSegmentIndex]
    }

    @objc private func redEyeChanged(_ sender: UISwitch) {
        enableRedEye = sender.isOn
    }

    @objc private func depthChanged(_ sender: UISwitch) {
        guard isDepthSupported else {
            sender.setOn(false, animated: true)
            CaptureHelper.showToast("Depth not supported", in: view)
            return
        }
        let isOn = sender.isOn
        enableDepth = isOn

        sessionManager.sessionQueue.async { [weak self] in
            guard let photoOutput = self?.sessionManager.photoOutput else { return }
            if isOn {
                PRMDepthHelper.enableDepthDataDelivery(on: photoOutput)
            } else {
                PRMDepthHelper.disableDepthDataDelivery(on: photoOutput)
            }
            let enabled = PRMDepthHelper.isDepthDataDeliveryEnabled(on: photoOutput)
            DispatchQueue.main.async {
                self?.depthStatusLabel.text = enabled
                    ? "Depth delivery enabled"
                    : "Depth delivery disabled"
            }
        }
    }

    @objc private func stabilizationChanged(_ sender: UISwitch) {
        enableStabilization = sender.isOn
    }

    @objc private func toggleSettings(_ sender: UIButton) {
        let isHidden = !settingsContainer.isHidden
        settingsContainer.isHidden = isHidden
        sender.setTitle(isHidden ? "Show Settings" : "Hide Settings", for: .normal)
    }

    // MARK: - Capture

    private func capturePhoto() {
        guard let photoOutput = sessionManager.photoOutput else { return }

        var builder = PRMPhotoSettingsBuilder()
            .flashMode(currentFlashMode)
            .qualityPrioritization(qualityPrioritization)
            .enableAutoStillImageStabilization(enableStabilization)
            .enableAutoRedEyeReduction(enableRedEye)

        if enableDepth, isDepthSupported {
            builder = builder.enableDepthDataDelivery(true)
        }

        let settings = builder.build()
        let captureFilter = currentFilter

        let processor = PRMPhotoCaptureProcessor(settings: settings) { photo -> Data? in
            guard let data = photo.fileDataRepresentation() else { return nil }

            if let captureFilter {
                if let ciImage = CIImage(data: data), let filtered = captureFilter.render(image: ciImage) {
                    return PRMImageHelper.jpegData(from: filtered)
                }
            }
            return data
        }

        processor.willCapturePhotoHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.previewView.alpha = 0
                UIView.animate(withDuration: 0.25) {
                    self?.previewView.alpha = 1
                }
            }
        }

        processor.processingStartedHandler = { [weak self] isProcessing in
            DispatchQueue.main.async {
                self?.processingLabel.isHidden = !isProcessing
            }
        }

        processor.completionHandler = { [weak self] completedProcessor in
            DispatchQueue.main.async {
                self?.activeProcessor = nil
                self?.processingLabel.isHidden = true
                guard let data = completedProcessor.capturedPhotoData else { return }
                self?.showCapturedPhoto(data: data)
            }
        }

        activeProcessor = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func showCapturedPhoto(data: Data) {
        let previewVC = PhotoPreviewViewController(photoData: data)
        navigationController?.pushViewController(previewVC, animated: true)
    }
}
