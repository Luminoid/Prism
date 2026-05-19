@preconcurrency import AVFoundation
import CoreImage
import Photos
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - BasicRendererViewController

/// Demonstrates `PRMBasicFilterRenderer` (single-filter pipeline) and `PRMPhotoCapture`'s
/// `capturePhoto(applying:context:willCapture:)` overload, which encodes a still photo through
/// a filter and preserves EXIF metadata.
///
/// Filter selection swaps the active renderer in/out — exercising
/// `PRMFilterPipeline.activeRenderer` mutation and `PRMFilterRenderer.reset()` lifecycle.
/// A "Snap" button captures a filtered photo via the `PRMPhotoSettings` builder using the
/// filter+context overload.
@MainActor
final class BasicRendererViewController: UIViewController {
    // MARK: - Filter catalog (single-filter, not chain)

    private struct Choice {
        let name: String
        let make: @Sendable () -> any PRMFilter
    }

    private let choices: [Choice] = [
        Choice(name: "Pass-through") { PRMPassThroughFilter() },
        Choice(name: "Brightness +") { PRMBrightnessFilter(value: 0.2) },
        Choice(name: "Sepia") { PRMSepiaFilter(intensity: 0.8) },
        Choice(name: "Grayscale") { PRMGrayscaleFilter() },
        Choice(name: "Comic") { PRMComicFilter() },
        Choice(name: "Edges") { PRMEdgesFilter() },
        Choice(name: "Pixellate") { PRMPixellateFilter(scale: 12) },
        Choice(name: "Twirl") { PRMTwirlDistortionFilter() },
        Choice(name: "Bump") { PRMBumpDistortionFilter() },
        Choice(name: "Pinch") { PRMPinchDistortionFilter() },
    ]

    private var activeChoice = 0

    // MARK: - Camera / pipeline

    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    private let renderContext: PRMRenderContext = {
        guard let context = PRMRenderContext(name: "BasicRenderer") else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var previewView = PRMPreviewView(context: renderContext)
    private var photoCapture: PRMPhotoCapture?

    // MARK: - UI

    private let segmentedHost = UIScrollView()
    private let segmentedStack = UIStackView()
    private let snapButton = UIButton(type: .system)
    private let dimensionsToggle = UISwitch()
    private let dimensionsLabel = UILabel()
    private let codecSegmented = UISegmentedControl(items: ["JPEG", "HEIC"])
    private let statusLabel = UILabel()

    private var capMaxDimensions: Bool = false
    private var preferredCodec: AVVideoCodecType = .hevc

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = "Basic Renderer"
        setupLayout()
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await camera.stop() }
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(previewView)
        previewView.rotation = .rotate90
        previewView.contentFit = .fill
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.55)
        }

        // Filter chooser — horizontal scroll of pills.
        segmentedStack.axis = .horizontal
        segmentedStack.spacing = 8
        segmentedHost.addSubview(segmentedStack)
        segmentedHost.showsHorizontalScrollIndicator = false
        view.addSubview(segmentedHost)
        segmentedHost.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(40)
        }
        segmentedStack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
            $0.height.equalToSuperview()
        }
        for (index, choice) in choices.enumerated() {
            let pill = ChoicePill(title: choice.name)
            pill.onTap = { [weak self] in self?.select(index) }
            segmentedStack.addArrangedSubview(pill)
        }

        // PRMPhotoSettings.maxDimensions toggle.
        dimensionsLabel.text = "Cap to maxPhotoDimensions"
        dimensionsLabel.textColor = .white
        dimensionsLabel.font = .systemFont(ofSize: 13)
        let dimRow = UIStackView(arrangedSubviews: [dimensionsLabel, dimensionsToggle])
        dimRow.axis = .horizontal
        dimRow.distribution = .equalSpacing
        dimensionsToggle.addAction(UIAction { [weak self] _ in
            self?.capMaxDimensions = self?.dimensionsToggle.isOn ?? false
        }, for: .valueChanged)
        view.addSubview(dimRow)
        dimRow.snp.makeConstraints {
            $0.top.equalTo(segmentedHost.snp.bottom).offset(14)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(32)
        }

        // PRMPhotoSettings.codec selector.
        codecSegmented.selectedSegmentIndex = 1
        codecSegmented.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            preferredCodec = codecSegmented.selectedSegmentIndex == 0 ? .jpeg : .hevc
        }, for: .valueChanged)
        view.addSubview(codecSegmented)
        codecSegmented.snp.makeConstraints {
            $0.top.equalTo(dimRow.snp.bottom).offset(10)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(28)
        }

        // Snap button — capturePhoto(applying:context:) overload.
        var snapConfig = UIButton.Configuration.filled()
        snapConfig.title = "Snap filtered photo"
        snapConfig.baseBackgroundColor = .systemYellow
        snapConfig.baseForegroundColor = .black
        snapConfig.cornerStyle = .large
        snapButton.configuration = snapConfig
        snapButton.addAction(UIAction { [weak self] _ in self?.snap() }, for: .touchUpInside)
        view.addSubview(snapButton)
        snapButton.snp.makeConstraints {
            $0.top.equalTo(codecSegmented.snp.bottom).offset(14)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(48)
        }

        statusLabel.text = "Tap a filter, then Snap to save a filtered photo with EXIF preserved."
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(snapButton.snp.bottom).offset(10)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
        }
    }

    // MARK: - Boot

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        do {
            try await camera.configure(PRMCameraConfiguration())
        } catch {
            statusLabel.text = "Cannot start camera: \(error.localizedDescription)"
            return
        }
        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.previewView.update(frame.pixelBuffer)
        }
        applyChoice()

        await PRMCameraActor.shared.run { [self] in
            if let photoOutput = await camera.session.photoOutput {
                let capture = PRMPhotoCapture(output: photoOutput)
                await MainActor.run { self.photoCapture = capture }
            }
        }

        await camera.start()
    }

    // MARK: - Filter selection

    private func select(_ index: Int) {
        guard index >= 0, index < choices.count else { return }
        activeChoice = index
        applyChoice()
        refreshPillSelection()
    }

    private func applyChoice() {
        let choice = choices[activeChoice]
        // PRMBasicFilterRenderer — single-filter renderer (not chain). Setting `activeRenderer`
        // tears down the previous one and swaps in this one cleanly.
        let renderer = PRMBasicFilterRenderer(
            context: renderContext,
            description: choice.name,
            filterFactory: choice.make
        )
        pipeline.activeRenderer = renderer
    }

    private func refreshPillSelection() {
        for (index, view) in segmentedStack.arrangedSubviews.enumerated() {
            (view as? ChoicePill)?.isActive = index == activeChoice
        }
    }

    // MARK: - Snap

    private func snap() {
        guard let photoCapture else { return }
        let choice = choices[activeChoice]
        var settings = PRMPhotoSettings()
            .flashMode(.off)
            .qualityPrioritization(.quality)
            .codec(preferredCodec)
        if capMaxDimensions {
            settings = settings.maxDimensions(photoCapture.output.maxPhotoDimensions)
        }

        statusLabel.text = "Capturing…"
        Task {
            do {
                let photo = try await photoCapture.capturePhoto(
                    settings: settings,
                    applying: choice.make(),
                    context: renderContext,
                    willCapture: { [weak self] in
                        Task { @MainActor [weak self] in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            self?.statusLabel.text = "Shutter open…"
                        }
                    }
                )
                await save(data: photo.data)
            } catch {
                statusLabel.text = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func save(data: Data) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        let granted = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard granted == .authorized || granted == .limited else {
            statusLabel.text = "Photo library access denied."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
            }
            statusLabel.text = "Saved filtered photo to library."
        } catch {
            statusLabel.text = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - ChoicePill

private final class ChoicePill: UIControl {
    var onTap: (() -> Void)?
    var isActive: Bool = false {
        didSet { apply() }
    }

    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        layer.cornerRadius = 14
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        label.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    @objc private func handleTap() {
        onTap?()
    }

    private func apply() {
        backgroundColor = isActive
            ? UIColor.systemYellow
            : UIColor.white.withAlphaComponent(0.08)
        label.textColor = isActive ? .black : .white
    }
}
