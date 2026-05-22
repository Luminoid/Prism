@preconcurrency import AVFoundation
import CoreImage
import Photos
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - FilterChainViewController

/// Interactive filter chain editor + filtered photo capture.
///
/// - Top half: filtered preview.
/// - Bottom half: chain editor (active filters + library to add).
/// - Active filter pills can be reordered (long-press) or removed (swipe to remove).
/// - Tap an active pill to open an intensity slider.
/// - "Snap" captures a still photo with the *entire chain* baked in via
///   ``PRMPhotoCapture/capturePhoto(settings:applyingChain:context:willCapture:)`` and
///   saves it to the photo library with the original EXIF preserved.
/// - Codec (JPEG / HEIC) and `maxPhotoDimensions` toggle exercise ``PRMPhotoSettings``
///   the same way the (now-retired) BasicRenderer demo did.
@MainActor
final class FilterChainViewController: UIViewController {
    // MARK: - Filter catalog

    private struct CatalogEntry {
        let name: String
        let category: Category
        let make: @Sendable () -> any PRMFilter
    }

    private enum Category: String, CaseIterable {
        case color = "Color"
        case blur = "Blur"
        case stylize = "Stylize"
        case distort = "Distort"
        case other = "Other"
    }

    private let catalog: [CatalogEntry] = [
        .init(name: "Brightness", category: .color) { PRMBrightnessFilter(value: 0.15) },
        .init(name: "Sepia", category: .color) { PRMSepiaFilter() },
        .init(name: "Vignette", category: .color) { PRMVignetteFilter() },
        .init(name: "Grayscale", category: .color) { PRMGrayscaleFilter() },
        .init(name: "Saturation", category: .color) { PRMSaturationFilter(value: 1.8) },
        .init(name: "Contrast", category: .color) { PRMContrastFilter(value: 1.4) },
        .init(name: "Hue", category: .color) { PRMHueRotationFilter(angle: 1.0) },

        .init(name: "Gaussian", category: .blur) { PRMGaussianBlurFilter(radius: 6) },
        .init(name: "Motion", category: .blur) { PRMMotionBlurFilter(radius: 15) },
        .init(name: "Zoom", category: .blur) { PRMZoomBlurFilter(amount: 10) },

        .init(name: "Pixellate", category: .stylize) { PRMPixellateFilter(scale: 8) },
        .init(name: "Comic", category: .stylize) { PRMComicFilter() },
        .init(name: "Pointillize", category: .stylize) { PRMPointillizeFilter(radius: 10) },
        .init(name: "Edges", category: .stylize) { PRMEdgesFilter() },

        .init(name: "Bump", category: .distort) { PRMBumpDistortionFilter() },
        .init(name: "Twirl", category: .distort) { PRMTwirlDistortionFilter() },
        .init(name: "Pinch", category: .distort) { PRMPinchDistortionFilter() },
        .init(name: "Vortex", category: .distort) { PRMVortexDistortionFilter() },

        .init(name: "Pass-through", category: .other) { PRMPassThroughFilter() },
    ]

    // MARK: - Camera / pipeline

    private let camera = PRMCamera()
    private let pipeline = PRMFilterPipeline()
    /// See StudioViewController for the reasoning behind the fatalError fallback.
    private let renderContext: PRMRenderContext = {
        guard let context = PRMRenderContext() else {
            fatalError("Metal is unavailable on this device — Prism preview requires Metal.")
        }
        return context
    }()

    private lazy var previewView = PRMPreviewView(context: renderContext)
    private lazy var chain: PRMFilterChain = .init(context: renderContext, description: "ChainDemo")
    private var photoCapture: PRMPhotoCapture?

    /// Codec / maxDimensions toggles plumbed through `PRMPhotoSettings`. Defaults match
    /// Apple Camera (HEIC, no cap).
    private var preferredCodec: AVVideoCodecType = .hevc
    private var capMaxDimensions: Bool = false

    // MARK: - UI

    private let activeStackContainer = UIScrollView()
    private let activeStack = UIStackView()
    private let categorySegmented = UISegmentedControl(items: Category.allCases.map(\.rawValue))
    private let libraryScroll = UIScrollView()
    private let libraryStack = UIStackView()
    private let activeEmptyLabel = UILabel()

    /// Chain-management toolbar that exercises `PRMFilterChain.removeAll`, `.move`, `.setIntensity`.
    private let toolbarStack = UIStackView()
    private let clearButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let randomizeButton = UIButton(type: .system)

    /// Snap UI — captures a still with the full chain baked in via the new
    /// `PRMPhotoCapture.capturePhoto(applyingChain:context:)` API. Migrated from the
    /// retired BasicRenderer demo, which only supported a single filter at encode time.
    private let snapButton = UIButton(type: .system)
    private let codecSegmented = UISegmentedControl(items: ["JPEG", "HEIC"])
    private let dimensionsToggle = UISwitch()
    private let snapStatusLabel = UILabel()

    /// `frameStream()` telemetry — runs alongside `onFrame` to demonstrate dual delivery.
    private let fpsLabel = UILabel()
    private var frameStreamTask: Task<Void, Never>?
    private var frameStreamFrameCount: Int = 0
    private var fpsTimer: Timer?

    /// In-memory mirror of `chain.entries` to bind to the visual stack.
    private var activeEntries: [(uuid: UUID, name: String, make: @Sendable () -> any PRMFilter, intensity: Float)] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = "Filter Chain"
        setupLayout()
        wireSnapRow()
        rebuildLibrary()
        Task { await bootCamera() }
    }

    // MARK: - Snap row

    /// Configures the Snap UI (codec picker, maxDimensions toggle, snap button, status).
    /// Called from `viewDidLoad` after `setupLayout` lays out the chain editor — the
    /// snap row hugs the top of the preview (right under the FPS chip) so it stays
    /// reachable as the chain editor grows in the bottom half.
    private func wireSnapRow() {
        codecSegmented.selectedSegmentIndex = preferredCodec == .jpeg ? 0 : 1
        codecSegmented.selectedSegmentTintColor = .systemYellow
        codecSegmented.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        codecSegmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)],
            for: .normal
        )
        codecSegmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)],
            for: .selected
        )
        codecSegmented.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            preferredCodec = codecSegmented.selectedSegmentIndex == 0 ? .jpeg : .hevc
        }, for: .valueChanged)

        // Standalone UISwitch — `UISwitch.title` and `.preferredStyle = .checkbox` are
        // both Mac Catalyst Mac-idiom-only and crash with
        // `_UICatalystUnsupportedMacIdiomBehavior` on iPhone / iPad. Pair the switch with
        // its own UILabel and let the stack view lay them out side-by-side.
        dimensionsToggle.isOn = capMaxDimensions
        dimensionsToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            capMaxDimensions = dimensionsToggle.isOn
        }, for: .valueChanged)
        // Slim the switch so the row fits the preview's trailing margin on iPhone width.
        dimensionsToggle.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

        // "Max" toggles `PRMPhotoSettings.maxDimensions` to the LARGEST entry in
        // `activeFormat.supportedMaxPhotoDimensions` (typically 48MP on iPhone 14 Pro+).
        // OFF means leave `maxPhotoDimensions` unset, which delivers the format's default
        // (typically 12MP for `.photo` preset, 4032×3024). The earlier "2K cap" attempt
        // didn't work because `.photo` preset only exposes 4032×3024 and 8064×6048 —
        // neither is under 2K, so the cap was a no-op. Flipping the semantics to
        // "max vs default" produces a visible difference on every supported device.
        let dimLabel = UILabel()
        dimLabel.text = "Max"
        dimLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        dimLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        dimLabel.setContentHuggingPriority(.required, for: .horizontal)
        dimLabel.isAccessibilityElement = true
        dimLabel.accessibilityHint = "Use the largest supported photo dimensions (48MP on Pro models)"
        dimensionsToggle.accessibilityLabel = "Capture at max resolution"

        var snapConfig = UIButton.Configuration.filled()
        snapConfig.title = "Snap"
        snapConfig.baseBackgroundColor = .systemYellow
        snapConfig.baseForegroundColor = .black
        snapConfig.cornerStyle = .medium
        snapConfig.titleTextAttributesTransformer = .init { input in
            var attrs = input
            attrs.font = .systemFont(ofSize: 13, weight: .bold)
            return attrs
        }
        snapButton.configuration = snapConfig
        snapButton.addAction(UIAction { [weak self] _ in self?.snap() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [codecSegmented, dimLabel, dimensionsToggle, snapButton])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        view.addSubview(row)
        // Anchor below the FPS chip on the right side of the preview.
        row.snp.makeConstraints {
            $0.top.equalTo(fpsLabel.snp.bottom).offset(8)
            $0.trailing.equalToSuperview().offset(-12)
            $0.height.equalTo(30)
        }
        snapButton.snp.makeConstraints { $0.width.equalTo(70) }
        codecSegmented.snp.makeConstraints { $0.width.equalTo(86) }

        snapStatusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        snapStatusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        snapStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        snapStatusLabel.layer.cornerRadius = 6
        snapStatusLabel.layer.masksToBounds = true
        snapStatusLabel.textAlignment = .center
        snapStatusLabel.text = " Snap the chain "
        view.addSubview(snapStatusLabel)
        snapStatusLabel.snp.makeConstraints {
            $0.top.equalTo(row.snp.bottom).offset(6)
            $0.trailing.equalToSuperview().offset(-12)
            $0.height.equalTo(20)
            $0.width.greaterThanOrEqualTo(96)
        }
    }

    /// Captures a still through the active chain. Empty chain → straight encode
    /// (skips the CIImage round-trip). Non-empty → `PRMPhotoCapture.capturePhoto(applyingChain:context:)`
    /// which bakes every filter with intensity blending — same math as the live preview.
    private func snap() {
        guard let photoCapture else { return }
        let entries = activeEntries.map { entry in
            PRMFilterChain.Entry(filter: entry.make(), intensity: entry.intensity)
        }
        let codecChoice = preferredCodec
        let wantsCap = capMaxDimensions
        snapStatusLabel.text = " Capturing… "
        Task { [photoCapture, renderContext, weak self] in
            guard let self else { return }
            var settings = PRMPhotoSettings()
                .flashMode(.off)
                .qualityPrioritization(.quality)
                .codec(codecChoice)
            var capLabel = ""
            if wantsCap, let maxDims = await maxSupportedDimensions() {
                settings = settings.maxDimensions(maxDims)
                capLabel = " · max \(maxDims.width)×\(maxDims.height)"
            }
            do {
                let willCapture: (@Sendable () -> Void) = { [weak self] in
                    Task { @MainActor [weak self] in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        self?.snapStatusLabel.text = " Shutter open "
                    }
                }
                let photo = entries.isEmpty
                    ? try await photoCapture.capturePhoto(
                        settings: settings,
                        willCapture: willCapture
                    )
                    : try await photoCapture.capturePhoto(
                        settings: settings,
                        applyingChain: entries,
                        context: renderContext,
                        willCapture: willCapture
                    )
                await save(data: photo.data, extraStatus: capLabel)
            } catch {
                await MainActor.run { [weak self] in
                    self?.snapStatusLabel.text = " Capture failed "
                }
            }
        }
    }

    private func save(data: Data, extraStatus: String = "") async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        let granted = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard granted == .authorized || granted == .limited else {
            snapStatusLabel.text = " Photos denied "
            return
        }
        do {
            try await Self.writePhoto(data: data)
            // Surface the actual encoded type, file size, and (when 2K cap on) the
            // exact dimensions AVFoundation picked from `supportedMaxPhotoDimensions`.
            // JPEG and HEIC magic bytes differ — sniffing them locally is the only
            // reliable way to verify which encoder won, since Photos.app hides the
            // file extension.
            let label = Self.codecLabel(for: data)
            let sizeKB = data.count / 1024
            snapStatusLabel.text = " Saved \(label) · \(sizeKB) KB\(extraStatus) "
        } catch {
            snapStatusLabel.text = " Save failed "
        }
    }

    /// Detect the encoded container by peeking at the first few bytes. `0xFF 0xD8` is
    /// the JPEG SOI marker; `ftyp...heic`/`mif1` is HEIF. Lets the snap status confirm
    /// which encoder actually ran (the chain path may fall back to JPEG when the
    /// device can't HEIF-encode — useful debug signal).
    private static func codecLabel(for data: Data) -> String {
        guard data.count >= 12 else { return "?" }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "JPEG" }
        // ISO base media: bytes 4..8 = "ftyp"
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "HEIC"
        }
        return "?"
    }

    /// `PHPhotoLibrary.performChanges` runs its closure on Photos' private queue. When
    /// the closure is created inside a `@MainActor` method it inherits MainActor
    /// isolation, and the concurrency runtime then aborts with
    /// `_dispatch_assert_queue_fail` when Photos tries to dispatch it. Wrapping the call
    /// in a `nonisolated static func` fully severs that isolation inheritance so the
    /// closure can run anywhere Photos wants to put it. Same pattern as the workspace
    /// `PHPhotoLibrary` / `BGTaskScheduler` lessons.
    private nonisolated static func writePhoto(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
        }
    }

    /// Returns the LARGEST entry in `activeFormat.supportedMaxPhotoDimensions`. On iPhone
    /// 14 Pro and later with the wide camera on `.photo` preset, this is the 48MP entry
    /// (8064×6048). On older / non-Pro devices it's the same as the default 12MP entry
    /// (4032×3024), so toggling Max produces no visible difference — flag that case in
    /// the snap status so the user knows it's a device limitation, not a bug.
    /// `AVCapturePhotoOutput.maxPhotoDimensions` must EXACTLY match one of the entries
    /// in `activeFormat.supportedMaxPhotoDimensions` — arbitrary cap values throw
    /// `NSInvalidArgumentException`.
    private func maxSupportedDimensions() async -> CMVideoDimensions? {
        let session = camera.session
        return await PRMCameraActor.shared.run {
            guard let device = await session.videoDevice else { return CMVideoDimensions?.none }
            // Same landscape filter as `selectHighestPhotoResolutionFormat` — some
            // formats expose portrait `supportedMaxPhotoDimensions` that don't
            // correspond to usable photo dimensions for AVCapturePhotoSettings.
            let supported = device.activeFormat.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
            return supported.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        }
    }

    /// Walk every format on the active device and pick the one whose
    /// `supportedMaxPhotoDimensions` contains the **largest landscape photo entry**.
    /// "Largest" is judged by `width * height` (not just `width`) and only photo-shaped
    /// (`landscape orientation, width ≥ height`) entries count — some video formats
    /// expose portrait `supportedMaxPhotoDimensions` (e.g. `(3024, 4032)`) that would
    /// otherwise win a width-only comparison and lock the wide camera to a 12MP video
    /// format. That's the bug the previous `.max(by: width)` heuristic produced on
    /// iPhone 15 Pro Max — captures landed at 3024×4032 because a video format ranked
    /// above the 48MP photo format.
    ///
    /// Also raises the photo output's own `maxPhotoDimensions` ceiling so per-photo
    /// settings can actually request the 48MP entry (the ceiling is read-only relative
    /// to the active format at the time it was set, so it has to be reapplied after a
    /// format swap). Same `beginConfiguration`/`commitConfiguration` envelope as Apple's
    /// AVCam ProRAW sample (dev-forum 715452 + 748321).
    private func selectHighestPhotoResolutionFormat() async {
        let session = camera.session
        await PRMCameraActor.shared.run {
            guard let device = await session.videoDevice,
                  let photoOutput = await session.photoOutput
            else { return }
            /// Score formats by the area of their largest landscape photo dimension.
            /// Video formats with portrait `supportedMaxPhotoDimensions` score 0 and
            /// are filtered out — they can never produce a usable still capture.
            func score(_ format: AVCaptureDevice.Format) -> Int32 {
                format.supportedMaxPhotoDimensions
                    .filter { $0.width >= $0.height }
                    .map { $0.width * $0.height }
                    .max() ?? 0
            }
            let candidates = device.formats.filter { score($0) > 0 }
            guard let bestFormat = candidates.max(by: { score($0) < score($1) }),
                  let largest = bestFormat.supportedMaxPhotoDimensions
                  .filter({ $0.width >= $0.height })
                  .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
            else { return }
            let sessionRef = session.session
            sessionRef.beginConfiguration()
            defer { sessionRef.commitConfiguration() }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.activeFormat != bestFormat {
                    device.activeFormat = bestFormat
                }
            } catch {
                return
            }
            photoOutput.maxPhotoDimensions = largest
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        frameStreamTask?.cancel()
        frameStreamTask = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        Task { await camera.stop() }
    }

    // MARK: - Layout

    private func setupLayout() {
        // Preview — top half
        view.addSubview(previewView)
        previewView.rotation = .rotate90
        previewView.contentFit = .fill
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.5)
        }

        // FPS readout (proves frameStream() delivery alongside onFrame).
        fpsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        fpsLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        fpsLabel.layer.cornerRadius = 6
        fpsLabel.layer.masksToBounds = true
        fpsLabel.textAlignment = .center
        fpsLabel.text = " stream … "
        view.addSubview(fpsLabel)
        fpsLabel.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            $0.trailing.equalToSuperview().offset(-12)
            $0.height.equalTo(22)
            $0.width.greaterThanOrEqualTo(96)
        }

        // Bottom container
        let drawer = UIView()
        drawer.backgroundColor = UIColor.black
        view.addSubview(drawer)
        drawer.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom)
            $0.leading.trailing.bottom.equalToSuperview()
        }

        // Active filters section
        let activeHeader = SectionHeader(title: "ACTIVE CHAIN")
        drawer.addSubview(activeHeader)
        activeHeader.snp.makeConstraints {
            $0.top.equalToSuperview().offset(12)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
        }

        activeStack.axis = .horizontal
        activeStack.spacing = 8
        activeStack.alignment = .center

        activeStackContainer.addSubview(activeStack)
        activeStackContainer.showsHorizontalScrollIndicator = false
        drawer.addSubview(activeStackContainer)
        activeStackContainer.snp.makeConstraints {
            $0.top.equalTo(activeHeader.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(40)
        }
        activeStack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
            $0.height.equalToSuperview()
        }

        activeEmptyLabel.text = "Tap a filter below to add it"
        activeEmptyLabel.textColor = UIColor.white.withAlphaComponent(0.4)
        activeEmptyLabel.font = .systemFont(ofSize: 13)
        drawer.addSubview(activeEmptyLabel)
        activeEmptyLabel.snp.makeConstraints {
            $0.centerY.equalTo(activeStackContainer)
            $0.leading.equalToSuperview().offset(20)
        }

        // Chain-management toolbar.
        configureToolbarButton(clearButton, title: "Clear")
        configureToolbarButton(shuffleButton, title: "Shuffle")
        configureToolbarButton(randomizeButton, title: "Random Intensity")
        clearButton.addAction(UIAction { [weak self] _ in self?.clearChain() }, for: .touchUpInside)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.shuffleChain() }, for: .touchUpInside)
        randomizeButton.addAction(UIAction { [weak self] _ in self?.randomizeIntensities() }, for: .touchUpInside)

        toolbarStack.axis = .horizontal
        toolbarStack.spacing = 8
        toolbarStack.distribution = .fillEqually
        toolbarStack.addArrangedSubview(clearButton)
        toolbarStack.addArrangedSubview(shuffleButton)
        toolbarStack.addArrangedSubview(randomizeButton)
        drawer.addSubview(toolbarStack)
        toolbarStack.snp.makeConstraints {
            $0.top.equalTo(activeStackContainer.snp.bottom).offset(8)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(32)
        }

        // Category segmented
        categorySegmented.selectedSegmentIndex = 0
        categorySegmented.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        categorySegmented.selectedSegmentTintColor = .systemYellow
        categorySegmented.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        categorySegmented.setTitleTextAttributes([.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .selected)
        categorySegmented.addAction(UIAction { [weak self] _ in self?.rebuildLibrary() }, for: .valueChanged)
        drawer.addSubview(categorySegmented)
        categorySegmented.snp.makeConstraints {
            $0.top.equalTo(toolbarStack.snp.bottom).offset(12)
            $0.leading.equalToSuperview().offset(16)
            $0.trailing.equalToSuperview().offset(-16)
            $0.height.equalTo(32)
        }

        // Library scroll
        libraryStack.axis = .horizontal
        libraryStack.spacing = 8
        libraryScroll.addSubview(libraryStack)
        libraryScroll.showsHorizontalScrollIndicator = false
        drawer.addSubview(libraryScroll)
        libraryScroll.snp.makeConstraints {
            $0.top.equalTo(categorySegmented.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(44)
        }
        libraryStack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
            $0.height.equalToSuperview()
        }
    }

    private func configureToolbarButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .white
        config.background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = .init { input in
            var attributes = input
            attributes.font = .systemFont(ofSize: 11, weight: .semibold)
            return attributes
        }
        button.configuration = config
    }

    // MARK: - Toolbar actions (exercise PRMFilterChain.removeAll / move / setIntensity)

    private func clearChain() {
        activeEntries.removeAll()
        // Use the chain's `removeAll()` directly (rather than `replace([])`) to exercise that API.
        chain.removeAll()
        rebuildActiveStack()
    }

    private func shuffleChain() {
        guard activeEntries.count >= 2 else { return }
        // Drive PRMFilterChain.move by computing a Fisher-Yates-style swap sequence,
        // applying each move to both the mirror array and the chain.
        for index in stride(from: activeEntries.count - 1, through: 1, by: -1) {
            let target = Int.random(in: 0 ... index)
            guard target != index else { continue }
            activeEntries.swapAt(index, target)
            chain.move(from: index, to: target)
        }
        rebuildActiveStack()
    }

    private func randomizeIntensities() {
        for index in activeEntries.indices {
            let intensity = Float.random(in: 0.2 ... 1.0)
            activeEntries[index].intensity = intensity
            // Drive PRMFilterChain.setIntensity rather than rebuilding entries.
            chain.setIntensity(intensity, at: index)
        }
        rebuildActiveStack()
    }

    // MARK: - Camera boot

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        do {
            // Pin to the Wide camera. Triple/Dual virtual devices only expose 12MP
            // (4032×3024) in `supportedMaxPhotoDimensions` — only `builtInWideAngleCamera`
            // has formats with the 48MP entry (8064×6048) on iPhone 14 Pro+. Studio
            // intentionally keeps the Triple device for its multi-lens chip strip; the
            // FilterChain demo is the place to exercise full-resolution capture, so this
            // device choice is what makes the "Max" toggle actually do something visible.
            var config = PRMCameraConfiguration()
            config.deviceTypes = [.builtInWideAngleCamera]
            // Auto-deferred photo delivery and zero shutter lag both substitute a
            // smaller proxy capture path for the final still on iPhone 15 Pro+.
            // The user-facing symptom: Max toggles off, capture lands at the proxy
            // resolution (12MP) instead of the format's 48MP entry. Disable both
            // for the FilterChain demo where 48MP is the whole point of the
            // toggle — apps that want the lower-latency proxy path can opt back
            // in via PRMCameraConfiguration.
            config.enableAutoDeferredPhotoDelivery = false
            config.enableZeroShutterLag = false
            // Live Photo also forces a specific format pair that doesn't include
            // the 48MP entry on iPhone 15 Pro+. Default is already false; pin it
            // explicitly so future config defaults can't regress this surface.
            config.enableLivePhoto = false
            try await camera.configure(config)
            // After the session is up, hop the active format to one whose
            // `supportedMaxPhotoDimensions` contains the largest entry across all formats
            // — the `.photo` preset doesn't auto-pick the 48MP format on iPhone 15+ Pro,
            // so without this step the wide camera's `activeFormat` stays on a 12MP
            // format and Max still has nothing larger than 4032×3024 to pick.
            await selectHighestPhotoResolutionFormat()
        } catch {
            return
        }
        pipeline.activeRenderer = chain
        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.previewView.update(frame.pixelBuffer)
        }

        // Consume frameStream() in parallel — proves AsyncStream delivery works alongside onFrame.
        frameStreamTask = Task { [weak self, pipeline] in
            for await _ in pipeline.frameStream() {
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.frameStreamFrameCount += 1 }
            }
        }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                fpsLabel.text = " stream \(frameStreamFrameCount) fps "
                frameStreamFrameCount = 0
            }
        }

        // Wire `PRMPhotoCapture` so the Snap button can capture stills with the chain
        // baked in. The photoOutput lives on the camera actor; hop there to grab it,
        // construct the capture facade, and hop back to MainActor to store it.
        await PRMCameraActor.shared.run { [self] in
            if let photoOutput = await camera.session.photoOutput {
                let capture = PRMPhotoCapture(output: photoOutput)
                await MainActor.run { self.photoCapture = capture }
            }
        }

        await camera.start()
    }

    // MARK: - Library rebuild

    private func rebuildLibrary() {
        libraryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let category = Category.allCases[categorySegmented.selectedSegmentIndex]
        for entry in catalog where entry.category == category {
            let pill = LibraryPill(title: entry.name)
            pill.onTap = { [weak self] in self?.addFilter(entry) }
            libraryStack.addArrangedSubview(pill)
        }
    }

    private func addFilter(_ entry: CatalogEntry) {
        let uuid = UUID()
        activeEntries.append((uuid: uuid, name: entry.name, make: entry.make, intensity: 1.0))
        applyChain()
        rebuildActiveStack()
    }

    private func removeFilter(uuid: UUID) {
        activeEntries.removeAll { $0.uuid == uuid }
        applyChain()
        rebuildActiveStack()
    }

    private func updateIntensity(uuid: UUID, intensity: Float) {
        guard let index = activeEntries.firstIndex(where: { $0.uuid == uuid }) else { return }
        activeEntries[index].intensity = intensity
        applyChain()
    }

    private func applyChain() {
        let entries = activeEntries.map { entry in
            PRMFilterChain.Entry(filter: entry.make(), intensity: entry.intensity)
        }
        chain.replace(entries)
    }

    private func rebuildActiveStack() {
        activeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        activeEmptyLabel.isHidden = !activeEntries.isEmpty
        for entry in activeEntries {
            let pill = ActivePill(title: entry.name, intensity: entry.intensity)
            pill.onRemove = { [weak self] in self?.removeFilter(uuid: entry.uuid) }
            pill.onIntensityChanged = { [weak self] value in
                self?.updateIntensity(uuid: entry.uuid, intensity: value)
            }
            activeStack.addArrangedSubview(pill)
        }
    }
}

// MARK: - Subviews

private final class SectionHeader: UILabel {
    init(title: String) {
        super.init(frame: .zero)
        text = title
        font = .systemFont(ofSize: 10, weight: .bold)
        textColor = UIColor.white.withAlphaComponent(0.6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(title:) instead")
    }
}

private final class LibraryPill: UIControl {
    var onTap: (() -> Void)?
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 14
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(label)
        label.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    @objc private func handleTap() {
        UIView.animate(withDuration: 0.08, animations: { self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }, completion: { _ in
            UIView.animate(withDuration: 0.15) { self.transform = .identity }
        })
        onTap?()
    }
}

private final class ActivePill: UIControl {
    var onRemove: (() -> Void)?
    var onIntensityChanged: ((Float) -> Void)?

    private let titleLabel = UILabel()
    private let intensityLabel = UILabel()
    private var intensity: Float

    init(title: String, intensity: Float) {
        self.intensity = intensity
        super.init(frame: .zero)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
        layer.cornerRadius = 14
        layer.borderColor = UIColor.systemYellow.cgColor
        layer.borderWidth = 0.5

        titleLabel.text = title
        titleLabel.textColor = .systemYellow
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)

        // The chain applies a per-entry `intensity` (blend amount, 0–100 %) regardless of
        // the underlying filter's own params, so every pill has a meaningful adjustment.
        // Showing the current value inline makes it obvious that tapping the pill opens a
        // knob — without it the pill looks like a static chip. Format matches the
        // intensity sheet's label so the number doesn't jump on open / close.
        intensityLabel.text = "\(Int(round(intensity * 100)))%"
        intensityLabel.textColor = UIColor.systemYellow.withAlphaComponent(0.75)
        intensityLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)

        // Slider glyph hints that the pill is tappable for adjustment, distinguishing
        // this from the inert library pills below.
        let knobIcon = UIImageView(image: UIImage(systemName: "slider.horizontal.below.rectangle"))
        knobIcon.tintColor = UIColor.systemYellow.withAlphaComponent(0.75)
        knobIcon.contentMode = .scaleAspectFit
        knobIcon.snp.makeConstraints { $0.size.equalTo(11) }

        let stack = UIStackView(arrangedSubviews: [titleLabel, knobIcon, intensityLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        // UIStackView defaults to `isUserInteractionEnabled = true`. Even though its
        // children (UILabel/UIImageView) all default to interaction off, the stack
        // itself swallows hit-tests inside its frame because UIKit returns the deepest
        // interactive view at the touch — and that's the stack. The parent ActivePill
        // UIControl never sees the touch, so `.touchUpInside` doesn't fire and the
        // intensity sheet won't open. Switching it off makes the whole pill (minus the
        // trailing close hit area) report taps as expected.
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        // Reserve trailing space for the close button — it's now 28×28 (covers the
        // 44 pt HIG tap target across the contentInset). The number on the right reads
        // as "I'm at X%, tap to change."
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 36)) }

        // Tap → toggle intensity slider sheet.
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        // Long-press → remove with confirmation.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)

        // Trailing × button. Old version was 14×14 — way under the 44 pt HIG target —
        // and tapping it more often dismissed the keyboard / fell through to the pill's
        // own tap handler than removed the filter. Now a 28×28 visual glyph in a 36 pt
        // padded UIControl, so the hit area is comfortably ≥ 36 pt in both axes.
        let close = UIControl()
        let closeImage = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        closeImage.tintColor = .systemYellow
        closeImage.contentMode = .scaleAspectFit
        closeImage.isUserInteractionEnabled = false
        close.addSubview(closeImage)
        closeImage.snp.makeConstraints {
            $0.center.equalToSuperview()
            $0.size.equalTo(20)
        }
        addSubview(close)
        close.snp.makeConstraints {
            $0.trailing.equalToSuperview()
            $0.top.bottom.equalToSuperview()
            $0.width.equalTo(36)
        }
        close.addAction(UIAction { [weak self] _ in self?.handleClose() }, for: .touchUpInside)
    }

    /// Re-render the intensity readout — the host VC calls this when toolbar actions
    /// (Random Intensity, Shuffle) rebuild the chain so the pill text stays in sync.
    func setIntensity(_ value: Float) {
        intensity = value
        intensityLabel.text = "\(Int(round(value * 100)))%"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(title:intensity:) instead")
    }

    @objc private func handleTap() {
        presentIntensitySheet()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onRemove?()
        }
    }

    @objc private func handleClose() {
        onRemove?()
    }

    private func presentIntensitySheet() {
        guard let owner = window?.rootViewController else { return }
        let sheet = UIAlertController(title: titleLabel.text, message: "Intensity", preferredStyle: .actionSheet)
        let sliderHost = IntensitySliderView(initial: intensity) { [weak self] new in
            guard let self else { return }
            setIntensity(new)
            onIntensityChanged?(new)
        }
        sheet.view.addSubview(sliderHost)
        sliderHost.snp.makeConstraints {
            $0.top.equalToSuperview().offset(56)
            $0.leading.equalToSuperview().offset(20)
            $0.trailing.equalToSuperview().offset(-20)
            $0.height.equalTo(40)
        }
        sheet.view.snp.makeConstraints { $0.height.equalTo(160) }
        sheet.addAction(UIAlertAction(title: "Done", style: .cancel))
        owner.present(sheet, animated: true)
    }
}

private final class IntensitySliderView: UIView {
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private let onChange: (Float) -> Void

    init(initial: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = initial
        slider.minimumTrackTintColor = .systemYellow
        slider.addAction(UIAction { [weak self] _ in self?.handleChanged() }, for: .valueChanged)

        valueLabel.text = String(format: "%.0f%%", initial * 100)
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = .label
        valueLabel.textAlignment = .right
        valueLabel.snp.makeConstraints { $0.width.equalTo(46) }

        let stack = UIStackView(arrangedSubviews: [slider, valueLabel])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(initial:onChange:) instead")
    }

    private func handleChanged() {
        valueLabel.text = String(format: "%.0f%%", slider.value * 100)
        onChange(slider.value)
    }
}
