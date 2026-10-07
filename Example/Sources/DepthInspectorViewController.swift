@preconcurrency import AVFoundation
import CoreImage
import os
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - DepthInspectorViewController

/// Live depth next to the color preview.
///
/// Exercises the depth surface:
/// - `PRMCamera.enableDepthFormat()` to move to a format that streams depth,
/// - `PRMDepthCapture.isSupported(on:)` to gate the UI,
/// - `PRMDepthCapture.setEnabled(_:on:)` for depth delivery on the photo output,
/// - `PRMCameraSession.attachDepthDataOutput(delegate:queue:filteringEnabled:)` for the live
///   stream, which the session keeps across reconfigures,
/// - `PRMDepthCapture.setFiltering(_:on:)` for the temporal smoothing filter.
///
/// The depth map is converted to grayscale and drawn by a second `PRMPreviewView`, sized and
/// fitted like the color preview so the two line up point for point.
@MainActor
final class DepthInspectorViewController: UIViewController {
    // MARK: - Properties

    private let host = CameraPreviewHost(name: "DepthInspector.Color")
    /// A second render context, so the color and depth previews don't share a command queue.
    private let depthContext = CameraPreviewHost.makeRenderContext(name: "DepthInspector.Depth")
    private lazy var depthPreview = PRMPreviewView(context: depthContext)
    private lazy var depthDelegate = DepthDelegate(context: depthContext, previewView: depthPreview)
    private let depthQueue = DispatchQueue(label: "dev.luminoid.prism.example.depth", qos: .userInitiated)
    /// The live-preview and smoothing switches' camera calls, latest wins.
    private let runner = LatestWinsRunner()
    private lazy var toaster = ToastPresenter(hostView: view, below: host.previewView.snp.top)

    // MARK: - Views

    private lazy var statusLabel: PaddedLabel = {
        let label = PaddedLabel()
        label.text = "Checking depth support…"
        label.font = ExampleFont.scaled(13, weight: .medium, style: .footnote)
        label.textColor = .white
        label.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        label.numberOfLines = 0
        return label
    }()

    private lazy var enabledSwitch: UISwitch = {
        // On by default: the boot attaches the live depth output whenever the camera supports
        // depth, so the tile paints from the first frame. Off hides the tile and turns
        // photo-output depth delivery off.
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.isEnabled = false
        toggle.accessibilityLabel = "Live depth preview"
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            setDepthEnabled(toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }()

    private lazy var filteringSwitch: UISwitch = {
        // Off by default, so raw depth jitter can be compared with the smoothed stream.
        let toggle = UISwitch()
        toggle.isOn = false
        toggle.isEnabled = false
        toggle.accessibilityLabel = "Temporal smoothing"
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            setFiltering(toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.title = "Depth Inspector"
        navigationItem.largeTitleDisplayMode = .never
        host.delegate = self
        setupLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.viewWillAppear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        runner.cancelAll()
        host.viewDidDisappear()
    }

    // MARK: - Layout

    /// Laid out bottom-up so the switches and status always fit: they pin to the safe area's
    /// bottom and the two previews share the space above equally. Both previews use the same
    /// rotation and `.fit`, so a point in the color tile sits at the same place in the depth
    /// tile.
    private func setupLayout() {
        let toolbar = UIStackView(arrangedSubviews: [
            makeSwitchRow(title: "Live depth preview", toggle: enabledSwitch),
            makeSwitchRow(title: "Temporal smoothing (PRMDepthCapture.setFiltering)", toggle: filteringSwitch),
        ])
        toolbar.axis = .vertical
        toolbar.spacing = 12
        view.addSubview(toolbar)
        view.addSubview(statusLabel)

        let colorPreview = host.previewView
        colorPreview.contentFit = .fit
        view.addSubview(colorPreview)
        colorPreview.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
        }
        addTileLabel("COLOR", on: colorPreview)

        depthPreview.contentFit = .fit
        view.addSubview(depthPreview)
        depthPreview.snp.makeConstraints {
            $0.top.equalTo(colorPreview.snp.bottom)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(colorPreview)
            $0.bottom.equalTo(statusLabel.snp.top).offset(-12)
        }
        addTileLabel("DEPTH", on: depthPreview)

        statusLabel.snp.makeConstraints {
            $0.bottom.equalTo(toolbar.snp.top).offset(-12)
            $0.leading.trailing.equalToSuperview().inset(16)
        }
        toolbar.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-16)
        }
    }

    private func makeSwitchRow(title: String, toggle: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = ExampleFont.scaled(13, style: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        // The switch carries the label for VoiceOver.
        label.isAccessibilityElement = false
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func addTileLabel(_ text: String, on preview: PRMPreviewView) {
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = ExampleFont.monospaced(10, weight: .bold, style: .caption2, maximum: 14)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(label)
        label.snp.makeConstraints {
            $0.top.equalTo(preview).offset(8)
            $0.leading.equalTo(preview).offset(12)
        }
    }

    // MARK: - Actions

    /// Off hides the tile and stops the delegate drawing (cheaper than detaching the output),
    /// and turns photo-output depth delivery off as well.
    private func setDepthEnabled(_ enabled: Bool) {
        depthDelegate.isDeliveryEnabled = enabled
        let alpha: CGFloat = enabled ? 1 : 0
        if UIAccessibility.isReduceMotionEnabled {
            depthPreview.alpha = alpha
        } else {
            UIView.animate(withDuration: 0.2) { [depthPreview] in depthPreview.alpha = alpha }
        }
        statusLabel.text = enabled
            ? "Live depth preview on. Toggle smoothing to compare jitter."
            : "Live depth preview off (photo-output delivery also off)."
        runner.run("delivery") { [session = host.camera.session] in
            await Self.setPhotoDepthDelivery(enabled, on: session)
        }
    }

    private func setFiltering(_ enabled: Bool) {
        runner.run("filtering") { [session = host.camera.session] in
            await Self.setDepthFiltering(enabled, on: session)
        }
    }

    // MARK: - Camera actor helpers

    @PRMCameraActor
    private static func photoOutputSupportsDepth(_ session: PRMCameraSession) -> Bool {
        session.photoOutput.map(PRMDepthCapture.isSupported(on:)) ?? false
    }

    @PRMCameraActor
    private static func setPhotoDepthDelivery(_ enabled: Bool, on session: PRMCameraSession) {
        guard let photoOutput = session.photoOutput else { return }
        PRMDepthCapture.setEnabled(enabled, on: photoOutput)
    }

    @PRMCameraActor
    private static func setDepthFiltering(_ enabled: Bool, on session: PRMCameraSession) {
        guard let output = session.depthDataOutput else { return }
        PRMDepthCapture.setFiltering(enabled, on: output)
    }
}

// MARK: - CameraPreviewHostDelegate

extension DepthInspectorViewController: CameraPreviewHostDelegate {
    func cameraHostConfigure(_ host: CameraPreviewHost) async throws {
        var configuration = PRMCameraConfiguration()
        // Cameras without dual / triple / TrueDepth hardware can't deliver depth. Ask anyway
        // and let the support check decide.
        configuration.enableDepthDataDelivery = true
        try await host.camera.configure(configuration)
    }

    func cameraHostDidConfigure(_ host: CameraPreviewHost) async {
        // The `.photo` preset's default format on Pro iPhones streams no depth.
        let hasDepthFormat = await host.camera.enableDepthFormat()
        let session = host.camera.session
        let supported = await Self.photoOutputSupportsDepth(session)
        guard supported else {
            depthPreview.alpha = 0
            statusLabel.text = "This camera doesn't deliver depth data (no dual, triple or TrueDepth camera)."
            return
        }
        // Delivery on the photo output too, so a depth-aware capture would get depth.
        await Self.setPhotoDepthDelivery(true, on: session)
        do {
            try await session.attachDepthDataOutput(delegate: depthDelegate, queue: depthQueue, filteringEnabled: filteringSwitch.isOn)
        } catch {
            statusLabel.text = "Couldn't attach the depth stream."
            toaster.report(error, context: "Depth stream")
            return
        }
        enabledSwitch.isEnabled = true
        filteringSwitch.isEnabled = true
        depthDelegate.isDeliveryEnabled = enabledSwitch.isOn
        depthPreview.alpha = enabledSwitch.isOn ? 1 : 0
        statusLabel.text = hasDepthFormat
            ? "Depth format active; live depth preview on. Toggle smoothing to compare jitter."
            : "No depth-capable format on this camera; the depth stream may stay empty."
    }

    func cameraHost(_: CameraPreviewHost, didFailToConfigure error: any Error) {
        statusLabel.text = "Cannot start the camera."
        toaster.report(error, context: "Camera start")
    }

    func cameraHost(_: CameraPreviewHost, didReceive error: PRMSessionError) {
        toaster.report(error, context: "Camera")
    }

    func cameraHost(_: CameraPreviewHost, didOrientPreview rotation: PRMPreviewView.Rotation, mirroring: Bool) {
        // Depth maps arrive in the same sensor orientation as the color frames.
        depthPreview.rotation = rotation
        depthPreview.mirroring = mirroring
    }
}

// MARK: - DepthDelegate

/// Turns depth frames into grayscale pixel buffers for the depth preview, on the depth queue.
///
/// `isDeliveryEnabled` is written on the main actor and read on the depth queue, so it lives
/// behind a lock; the pixel-buffer pool is only touched on the depth queue (a serial queue).
private final class DepthDelegate: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    // MARK: - Properties

    private let context: PRMRenderContext
    private weak var previewView: PRMPreviewView?
    private let deliveryEnabled = OSAllocatedUnfairLock(initialState: true)
    private var cachedPool: CVPixelBufferPool?
    private var cachedPoolWidth = 0
    private var cachedPoolHeight = 0

    /// When `false` the delegate drops frames and the tile stops updating.
    var isDeliveryEnabled: Bool {
        get { deliveryEnabled.withLock { $0 } }
        set { deliveryEnabled.withLock { $0 = newValue } }
    }

    // MARK: - Init

    init(context: PRMRenderContext, previewView: PRMPreviewView) {
        self.context = context
        self.previewView = previewView
        super.init()
    }

    // MARK: - AVCaptureDepthDataOutputDelegate

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard isDeliveryEnabled else { return }
        let disparity = depthData.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = disparity.depthDataMap
        // Spread disparity across the visible range: desaturate and raise the contrast.
        let image = CIImage(cvPixelBuffer: map).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 4.0,
            kCIInputBrightnessKey: -0.2,
        ])
        guard let pool = depthPool(width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map)) else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return }
        context.ciContext.render(image, to: buffer)
        // `update(_:)` is nonisolated and lock-protected.
        previewView?.update(buffer)
    }

    // MARK: - Helpers

    private func depthPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let cachedPool, cachedPoolWidth == width, cachedPoolHeight == height {
            return cachedPool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        cachedPool = pool
        cachedPoolWidth = width
        cachedPoolHeight = height
        return pool
    }
}
