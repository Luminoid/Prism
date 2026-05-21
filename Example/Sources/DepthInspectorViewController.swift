@preconcurrency import AVFoundation
import CoreImage
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - DepthInspectorViewController

/// Live depth-data inspector built on `PRMDepthCapture`.
///
/// Exercises the entire `PRMDepthCapture` enum:
/// - `isSupported(on:)` to gate the UI,
/// - `setEnabled(_:on:)` / `isEnabled(on:)` to toggle depth delivery on the photo output,
/// - `addDepthDataOutput(to:delegate:queue:)` to attach a live `AVCaptureDepthDataOutput`,
/// - `setFiltering(_:on:)` to toggle the temporal smoothing filter.
///
/// The depth map is converted to a grayscale CIImage and pushed to a `PRMPreviewView` next to
/// the color preview so the two streams can be compared side-by-side.
@MainActor
final class DepthInspectorViewController: UIViewController {
    // MARK: - Camera / pipeline

    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()

    /// Two render contexts so the color and depth previews don't fight over a Metal command queue.
    private let colorContext: PRMRenderContext = {
        guard let context = PRMRenderContext(name: "DepthInspector.Color") else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private let depthContext: PRMRenderContext = {
        guard let context = PRMRenderContext(name: "DepthInspector.Depth") else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var colorPreview = PRMPreviewView(context: colorContext)
    private lazy var depthPreview = PRMPreviewView(context: depthContext)

    private var depthOutput: AVCaptureDepthDataOutput?
    private let depthQueue = DispatchQueue(label: "com.luminoid.PrismExample.Depth", qos: .userInitiated)
    private let depthDelegate = DepthDelegate()

    // MARK: - UI

    private let statusLabel = UILabel()
    private let filteringSwitch = UISwitch()
    private let enabledSwitch = UISwitch()
    private let filteringLabel = UILabel()
    private let enabledLabel = UILabel()
    private let toolbar = UIStackView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = "Depth Inspector"
        setupLayout()
        wireDepthDelegate()
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await camera.stop() }
    }

    // MARK: - Layout

    private func setupLayout() {
        // Color + depth share the same rotation and contentFit so a feature at view
        // coordinate (x, y) in the color preview lines up with the same coordinate in
        // the depth preview. The previous setup used `.fill` for color and `.fit` for
        // depth, which only matched if the screen happened to share the sensor's
        // aspect ratio — on every iPhone with a different half-screen aspect the depth
        // map would visibly slide vs. the color frame as the user moved the camera.
        // Both use `.fit` (letterbox the full sensor frame) so the user can directly
        // compare a point's depth against the corresponding color pixel.
        // Both previews use identical sizing + contentFit so the depth tile spatially
        // tracks the color tile. Equal heights (was 0.45 / 0.40 — slightly uneven) keep
        // the rotated portrait frames the same physical size, so a point in the color
        // preview lines up vertically with the same point in the depth preview.
        view.addSubview(colorPreview)
        colorPreview.rotation = .rotate90
        colorPreview.contentFit = .fit
        colorPreview.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.42)
        }
        addLabel("COLOR", on: colorPreview)

        view.addSubview(depthPreview)
        depthPreview.rotation = .rotate90
        depthPreview.contentFit = .fit
        depthPreview.snp.makeConstraints {
            $0.top.equalTo(colorPreview.snp.bottom)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(colorPreview)
        }
        addLabel("DEPTH", on: depthPreview)

        // Bottom control bar.
        statusLabel.text = "Checking depth support…"
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(depthPreview.snp.bottom).offset(12)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
        }

        enabledLabel.text = "Live depth preview"
        enabledLabel.textColor = .white
        enabledLabel.font = .systemFont(ofSize: 13)
        let enabledRow = UIStackView(arrangedSubviews: [enabledLabel, enabledSwitch])
        enabledRow.axis = .horizontal
        enabledRow.alignment = .center
        enabledRow.distribution = .equalSpacing
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.toggleDepthEnabled() }, for: .valueChanged)

        filteringLabel.text = "Temporal smoothing (PRMDepthCapture.setFiltering)"
        filteringLabel.textColor = .white
        filteringLabel.font = .systemFont(ofSize: 13)
        let filteringRow = UIStackView(arrangedSubviews: [filteringLabel, filteringSwitch])
        filteringRow.axis = .horizontal
        filteringRow.alignment = .center
        filteringRow.distribution = .equalSpacing
        filteringSwitch.isOn = true
        filteringSwitch.addAction(UIAction { [weak self] _ in self?.toggleFiltering() }, for: .valueChanged)

        toolbar.axis = .vertical
        toolbar.spacing = 12
        toolbar.addArrangedSubview(enabledRow)
        toolbar.addArrangedSubview(filteringRow)
        view.addSubview(toolbar)
        toolbar.snp.makeConstraints {
            $0.top.equalTo(statusLabel.snp.bottom).offset(16)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-16)
        }
    }

    private func addLabel(_ text: String, on preview: PRMPreviewView) {
        let label = UILabel()
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        view.addSubview(label)
        label.snp.makeConstraints {
            $0.top.equalTo(preview).offset(8)
            $0.leading.equalTo(preview).offset(12)
            $0.width.equalTo(60)
            $0.height.equalTo(20)
        }
    }

    private func wireDepthDelegate() {
        depthDelegate.context = depthContext
        depthDelegate.previewView = depthPreview
        // The "Photo-output depth delivery" toggle drives a flag the live-depth delegate
        // checks before painting. Without this the toggle had no visible effect: it only
        // gated `AVCapturePhotoOutput.isDepthDataDeliveryEnabled`, which is photo-only,
        // not the live preview. The live preview comes from a separately-attached
        // `AVCaptureDepthDataOutput`, so we drop frames at the delegate level to mirror
        // the photo gate's intent visually.
        depthDelegate.isDeliveryEnabled = true
    }

    // MARK: - Boot

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }

        do {
            var config = PRMCameraConfiguration()
            // Devices without dual/triple cameras can't deliver depth — request anyway, and let
            // PRMDepthCapture.isSupported tell us at runtime.
            config.enableDepthDataDelivery = true
            try await camera.configure(config)
        } catch {
            statusLabel.text = "Cannot start camera: \(error.localizedDescription)"
            return
        }

        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.colorPreview.update(frame.pixelBuffer)
        }

        await PRMCameraActor.shared.run { [self] in
            guard let photoOutput = await camera.session.photoOutput else { return }
            let supported = PRMDepthCapture.isSupported(on: photoOutput)
            let enabled = PRMDepthCapture.isEnabled(on: photoOutput)
            await MainActor.run {
                self.enabledSwitch.isOn = enabled
                self.enabledSwitch.isEnabled = supported
                self.filteringSwitch.isEnabled = supported
                self.statusLabel.text = supported
                    ? "Depth supported. Toggle delivery + filtering to see live depth map."
                    : "This device's camera does not deliver depth data (no dual/triple/TrueDepth camera)."
            }
            guard supported else { return }
            // Attach a live depth output so PRMPreviewView can render depth frames.
            if let session = await camera.session.session as AVCaptureSession?,
               let output = PRMDepthCapture.addDepthDataOutput(
                   to: session,
                   delegate: depthDelegate,
                   queue: depthQueue
               ) {
                PRMDepthCapture.setFiltering(true, on: output)
                await MainActor.run { self.depthOutput = output }
            }
        }

        await camera.start()
    }

    // MARK: - Actions

    private func toggleDepthEnabled() {
        let target = enabledSwitch.isOn
        // Mirror the toggle into the live-preview gate so flipping it actually changes
        // what the user sees on screen (otherwise it only affects photo capture). Off →
        // fully hide the depth tile so the user gets unambiguous feedback that the
        // toggle worked; on → restore full opacity and let the delegate push frames again.
        depthDelegate.isDeliveryEnabled = target
        UIView.animate(withDuration: 0.2) { [self] in
            depthPreview.alpha = target ? 1.0 : 0.0
        }
        statusLabel.text = target
            ? "Live depth preview on. Toggle smoothing to compare jitter."
            : "Live depth preview off (photo-output delivery also off)."
        Task { @PRMCameraActor in
            guard let photoOutput = await camera.session.photoOutput else { return }
            PRMDepthCapture.setEnabled(target, on: photoOutput)
        }
    }

    private func toggleFiltering() {
        guard let output = depthOutput else { return }
        PRMDepthCapture.setFiltering(filteringSwitch.isOn, on: output)
    }
}

// MARK: - Depth delegate

private final class DepthDelegate: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    var context: PRMRenderContext?
    weak var previewView: PRMPreviewView?
    /// Mirrors the "Photo-output depth delivery" toggle. When `false` the delegate drops
    /// frames so the preview goes dark — mirrors the toggle's photo-side intent
    /// visually. AVFoundation always streams from `AVCaptureDepthDataOutput` once
    /// attached; we gate at the delegate instead of detaching the output (cheaper, no
    /// session reconfig churn).
    var isDeliveryEnabled: Bool = true

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard isDeliveryEnabled else { return }
        // Convert disparity to a normalized grayscale CIImage and push to the depth preview.
        let converted = depthData.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = converted.depthDataMap
        // Normalize disparity to 0...1 visually (CIImage already in float; clamp via tonemap).
        let ciImage = CIImage(cvPixelBuffer: map)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 4.0,
                kCIInputBrightnessKey: -0.2,
            ])

        guard let context, let pool = depthPool(width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map)) else { return }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let outputBuffer = output else { return }
        context.ciContext.render(ciImage, to: outputBuffer)
        previewView?.update(outputBuffer)
    }

    private var cachedPool: CVPixelBufferPool?
    private var cachedPoolWidth: Int = 0
    private var cachedPoolHeight: Int = 0

    private func depthPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let cachedPool, cachedPoolWidth == width, cachedPoolHeight == height {
            return cachedPool
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        cachedPool = pool
        cachedPoolWidth = width
        cachedPoolHeight = height
        return pool
    }
}
