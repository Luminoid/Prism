@preconcurrency import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - FilterChainViewController

/// Interactive filter chain editor + filtered photo capture.
///
/// - Top half: the filtered preview.
/// - Bottom half: the chain (active filters) and the library to add from.
/// - Tap an active pill for its intensity slider; its × (or a long press) removes it.
/// - "Snap" captures a still with the *entire chain* baked in via
///   ``PRMPhotoCapture/capturePhoto(settings:applyingChain:context:willCapture:)`` and
///   saves it to the photo library with the original EXIF preserved.
/// - Codec (JPEG / HEIC) and the Max switch exercise ``PRMPhotoSettings``.
@MainActor
final class FilterChainViewController: UIViewController {
    // MARK: - Types

    private struct CatalogEntry {
        let name: String
        let category: Category
        let make: @Sendable () -> any PRMFilter
    }

    private struct ActiveEntry {
        let id: UUID
        let name: String
        let make: @Sendable () -> any PRMFilter
        var intensity: Float
    }

    private enum Category: String, CaseIterable {
        case color = "Color"
        case blur = "Blur"
        case stylize = "Stylize"
        case distort = "Distort"
        case other = "Other"
    }

    // MARK: - Properties

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

    private let host = CameraPreviewHost(name: "FilterChain")
    private var camera: PRMCamera { host.camera }
    /// One persistent chain: edits replace its entries in place (rebuilding a chain per
    /// change would make the pipeline re-prepare and reallocate its buffer pool).
    private lazy var chain = PRMFilterChain(context: host.renderContext, description: "ChainDemo")
    private var photoCapture: PRMPhotoCapture?
    /// The chain as shown; `chain` follows it.
    private var activeEntries: [ActiveEntry] = []
    /// Defaults match the system Camera: HEIC, no size cap.
    private var preferredCodec: AVVideoCodecType = .hevc
    private var capMaxDimensions = false
    private var snapTask: Task<Void, Never>?
    /// Frames counted from `frameStream()`, which runs alongside `onFrame` to show both
    /// delivery paths at once.
    private var frameCount = 0

    private lazy var toaster = ToastPresenter(hostView: view, below: snapStatusLabel.snp.bottom)

    // MARK: - Views

    private lazy var fpsLabel = Self.makeStatusChip(text: "stream …", monospaced: true)
    private lazy var snapStatusLabel = Self.makeStatusChip(text: "Snap the chain", monospaced: false)

    private lazy var codecSegmented: UISegmentedControl = {
        let segmented = UISegmentedControl(items: ["JPEG", "HEIC"])
        segmented.selectedSegmentIndex = preferredCodec == .jpeg ? 0 : 1
        segmented.accessibilityLabel = "Photo codec"
        Self.styleSegmented(segmented, background: UIColor.black.withAlphaComponent(0.55))
        segmented.addAction(UIAction { [weak self] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            preferredCodec = segmented.selectedSegmentIndex == 0 ? .jpeg : .hevc
        }, for: .valueChanged)
        return segmented
    }()

    /// "Max" asks for the camera's largest photo size (48MP on iPhone 14 Pro and later with
    /// the wide camera); off leaves the format's default (12MP on the `.photo` preset).
    private lazy var dimensionsToggle: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = capMaxDimensions
        toggle.accessibilityLabel = "Capture at maximum resolution"
        toggle.accessibilityHint = "Uses the largest supported photo size, 48 megapixels on Pro models"
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            capMaxDimensions = toggle.isOn
        }, for: .valueChanged)
        return toggle
    }()

    private lazy var snapButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Snap"
        configuration.baseBackgroundColor = .systemYellow
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var attributes = input
            attributes.font = ExampleFont.scaled(13, weight: .bold, style: .subheadline, maximum: 20)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityHint = "Captures a photo with the whole chain applied"
        button.addAction(UIAction { [weak self] _ in self?.snap() }, for: .touchUpInside)
        return button
    }()

    private let activeScroll = UIScrollView()
    private let activeStack = UIStackView()
    private let activeEmptyLabel = UILabel()
    private let libraryScroll = UIScrollView()
    private let libraryStack = UIStackView()

    private lazy var categorySegmented: UISegmentedControl = {
        let segmented = UISegmentedControl(items: Category.allCases.map(\.rawValue))
        segmented.selectedSegmentIndex = 0
        segmented.accessibilityLabel = "Filter category"
        Self.styleSegmented(segmented, background: UIColor.white.withAlphaComponent(0.06))
        segmented.addAction(UIAction { [weak self] _ in self?.rebuildLibrary() }, for: .valueChanged)
        return segmented
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.title = "Filter Chain"
        navigationItem.largeTitleDisplayMode = .never
        host.delegate = self
        host.addLoop { [weak self, pipeline = host.pipeline] in
            for await _ in pipeline.frameStream() {
                self?.frameCount += 1
            }
        }
        host.addLoop { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.publishFrameRate()
            }
        }
        setupLayout()
        rebuildLibrary()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.viewWillAppear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A snap in flight finishes and saves before the camera stops.
        host.viewDidDisappear(awaiting: snapTask.map { [$0] } ?? [])
    }

    // MARK: - Layout

    private func setupLayout() {
        let previewView = host.previewView
        view.addSubview(previewView)
        // Letterbox the full frame, so the preview shows what Snap saves.
        previewView.contentFit = .fit
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.5)
        }

        view.addSubview(fpsLabel)
        fpsLabel.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            $0.trailing.equalToSuperview().offset(-12)
        }

        let maxLabel = UILabel()
        maxLabel.text = "Max"
        maxLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        maxLabel.font = ExampleFont.scaled(11, weight: .semibold, style: .caption1, maximum: 16)
        maxLabel.adjustsFontForContentSizeCategory = true
        maxLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The switch carries the label for VoiceOver.
        maxLabel.isAccessibilityElement = false
        let snapRow = UIStackView(arrangedSubviews: [codecSegmented, maxLabel, dimensionsToggle, snapButton])
        snapRow.axis = .horizontal
        snapRow.spacing = 6
        snapRow.alignment = .center
        view.addSubview(snapRow)
        snapRow.snp.makeConstraints {
            $0.top.equalTo(fpsLabel.snp.bottom).offset(8)
            $0.trailing.equalToSuperview().offset(-12)
            $0.height.equalTo(44)
        }
        snapButton.snp.makeConstraints {
            $0.width.equalTo(70)
            $0.height.equalTo(44)
        }
        codecSegmented.snp.makeConstraints { $0.width.equalTo(96) }

        view.addSubview(snapStatusLabel)
        snapStatusLabel.snp.makeConstraints {
            $0.top.equalTo(snapRow.snp.bottom).offset(6)
            $0.trailing.equalToSuperview().offset(-12)
            $0.leading.greaterThanOrEqualToSuperview().offset(12)
        }

        let drawer = UIView()
        drawer.backgroundColor = .black
        view.addSubview(drawer)
        drawer.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom)
            $0.leading.trailing.bottom.equalToSuperview()
        }
        layoutChainEditor(in: drawer)
    }

    private func layoutChainEditor(in drawer: UIView) {
        let activeHeader = SectionHeaderLabel("Active chain")
        drawer.addSubview(activeHeader)
        activeHeader.snp.makeConstraints {
            $0.top.equalToSuperview().offset(12)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

        activeStack.axis = .horizontal
        activeStack.spacing = 8
        activeStack.alignment = .fill
        activeScroll.addSubview(activeStack)
        activeScroll.showsHorizontalScrollIndicator = false
        drawer.addSubview(activeScroll)
        activeScroll.snp.makeConstraints {
            $0.top.equalTo(activeHeader.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalTo(44)
        }
        activeStack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
            $0.height.equalToSuperview()
        }

        activeEmptyLabel.text = "Tap a filter below to add it"
        activeEmptyLabel.textColor = UIColor.white.withAlphaComponent(0.4)
        activeEmptyLabel.font = ExampleFont.scaled(13, style: .footnote, maximum: 20)
        activeEmptyLabel.adjustsFontForContentSizeCategory = true
        drawer.addSubview(activeEmptyLabel)
        activeEmptyLabel.snp.makeConstraints {
            $0.centerY.equalTo(activeScroll)
            $0.leading.equalToSuperview().offset(20)
        }

        // Chain management: exercises `removeAll`, `replace` and `setIntensity`.
        let toolbar = UIStackView(arrangedSubviews: [
            makeToolbarButton(title: "Clear") { [weak self] in self?.clearChain() },
            makeToolbarButton(title: "Shuffle") { [weak self] in self?.shuffleChain() },
            makeToolbarButton(title: "Random Intensity") { [weak self] in self?.randomizeIntensities() },
        ])
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fillEqually
        drawer.addSubview(toolbar)
        toolbar.snp.makeConstraints {
            $0.top.equalTo(activeScroll.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.height.equalTo(44)
        }

        drawer.addSubview(categorySegmented)
        categorySegmented.snp.makeConstraints {
            $0.top.equalTo(toolbar.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview().inset(16)
        }

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

    private func makeToolbarButton(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        configuration.background.cornerRadius = 8
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var attributes = input
            attributes.font = ExampleFont.scaled(11, weight: .semibold, style: .caption1, maximum: 16)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private static func makeStatusChip(text: String, monospaced: Bool) -> PaddedLabel {
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        label.font = monospaced
            ? ExampleFont.monospaced(11, weight: .semibold, style: .caption1, maximum: 16)
            : ExampleFont.scaled(11, weight: .semibold, style: .caption1, maximum: 16)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.textAlignment = .center
        label.text = text
        return label
    }

    private static func styleSegmented(_ segmented: UISegmentedControl, background: UIColor) {
        let font = ExampleFont.scaled(12, weight: .semibold, style: .caption1, maximum: 17)
        segmented.backgroundColor = background
        segmented.selectedSegmentTintColor = .systemYellow
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: font], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.black, .font: font], for: .selected)
    }

    private func publishFrameRate() {
        fpsLabel.text = "stream \(frameCount) fps"
        frameCount = 0
    }

    // MARK: - Snap

    /// Captures a still through the active chain: an empty chain encodes straight, otherwise
    /// `capturePhoto(applyingChain:context:)` bakes every filter in with the same intensity
    /// blending as the preview.
    private func snap() {
        guard let photoCapture, snapTask == nil else { return }
        let entries = activeEntries.map { PRMFilterChain.Entry(filter: $0.make(), intensity: $0.intensity) }
        var settings = PRMPhotoSettings()
            .flashMode(.off)
            .qualityPrioritization(.quality)
            .codec(preferredCodec)
            .rotationAngle(host.captureRotationAngle)
        var sizeNote = ""
        // `PRMPhotoSettings` validates the size against the live output and falls back to the
        // largest one it accepts.
        if capMaxDimensions, let largest = camera.device?.maxSupportedPhotoDimensions {
            settings = settings.maxDimensions(largest)
            sizeNote = " · max \(largest.width)×\(largest.height)"
        }
        let context = host.renderContext
        snapStatusLabel.text = "Capturing…"
        snapButton.isEnabled = false
        snapTask = Task { [weak self, photoCapture] in
            let willCapture: @Sendable () -> Void = { [weak self] in
                // The capture queue calls this; hop to the main actor for the UI.
                Task { @MainActor [weak self] in self?.shutterDidOpen() }
            }
            do {
                let photo: PRMPhoto = if entries.isEmpty {
                    try await photoCapture.capturePhoto(settings: settings, willCapture: willCapture)
                } else {
                    try await photoCapture.capturePhoto(settings: settings, applyingChain: entries, context: context, willCapture: willCapture)
                }
                try await PhotoLibrarySaver.save(.photo(photo.data))
                // The container's first bytes say which encoder actually ran (the chain path
                // falls back to JPEG where HEIF encoding fails).
                let container = PhotoLibrarySaver.containerLabel(for: photo.data)
                self?.snapStatusLabel.text = "Saved \(container) · \(photo.data.count / 1024) KB\(sizeNote)"
            } catch {
                self?.snapStatusLabel.text = "Snap failed"
                self?.toaster.report(error, context: "Snap")
            }
            self?.snapButton.isEnabled = true
            self?.snapTask = nil
        }
    }

    private func shutterDidOpen() {
        UIImpactFeedbackGenerator(style: .light, view: snapButton).impactOccurred()
        snapStatusLabel.text = "Shutter open"
    }

    // MARK: - Chain editing

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
        activeEntries.append(ActiveEntry(id: UUID(), name: entry.name, make: entry.make, intensity: 1))
        applyChain()
    }

    private func removeFilter(id: UUID) {
        activeEntries.removeAll { $0.id == id }
        applyChain()
    }

    private func clearChain() {
        activeEntries.removeAll()
        chain.removeAll()
        rebuildActiveStack()
    }

    /// Shuffles the list, then rebuilds the chain from it, so the two can't disagree.
    private func shuffleChain() {
        guard activeEntries.count >= 2 else { return }
        activeEntries.shuffle()
        applyChain()
    }

    private func randomizeIntensities() {
        for index in activeEntries.indices {
            let intensity = Float.random(in: 0.2 ... 1.0)
            activeEntries[index].intensity = intensity
            chain.setIntensity(intensity, at: index)
        }
        rebuildActiveStack()
    }

    /// An intensity change edits one entry in place; the slider sends these at drag rate.
    private func updateIntensity(id: UUID, intensity: Float) {
        guard let index = activeEntries.firstIndex(where: { $0.id == id }) else { return }
        activeEntries[index].intensity = intensity
        chain.setIntensity(intensity, at: index)
    }

    /// Replaces the chain's entries with the list and redraws the pills.
    private func applyChain() {
        chain.replace(activeEntries.map { PRMFilterChain.Entry(filter: $0.make(), intensity: $0.intensity) })
        rebuildActiveStack()
    }

    private func rebuildActiveStack() {
        activeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        activeEmptyLabel.isHidden = !activeEntries.isEmpty
        for entry in activeEntries {
            let pill = ActivePill(title: entry.name, intensity: entry.intensity)
            pill.onRemove = { [weak self] in self?.removeFilter(id: entry.id) }
            pill.onTap = { [weak self, weak pill] in
                guard let self, let pill else { return }
                presentIntensitySheet(for: entry.id, pill: pill)
            }
            activeStack.addArrangedSubview(pill)
        }
    }

    /// A small sheet with the intensity slider, at a custom detent so the preview above stays
    /// visible while dragging.
    private func presentIntensitySheet(for id: UUID, pill: ActivePill) {
        guard presentedViewController == nil, let entry = activeEntries.first(where: { $0.id == id }) else { return }
        let sheet = IntensitySheetViewController(title: entry.name, intensity: entry.intensity) { [weak self, weak pill] value in
            pill?.setIntensity(value)
            self?.updateIntensity(id: id, intensity: value)
        }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.custom(identifier: .init("intensity")) { _ in 160 }]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }
}

// MARK: - CameraPreviewHostDelegate

extension FilterChainViewController: CameraPreviewHostDelegate {
    func cameraHostConfigure(_ host: CameraPreviewHost) async throws {
        var configuration = PRMCameraConfiguration()
        // The wide camera only: virtual devices top out at 12MP, and only the physical wide
        // camera has the 48MP format on iPhone 14 Pro and later. This demo is the place for
        // full-resolution capture (Studio keeps the virtual device for its lens chips).
        configuration.deviceTypes = [.builtInWideAngleCamera]
        // Auto-deferred delivery, zero shutter lag and Live Photo all substitute 12MP paths
        // for the final still on iPhone 15 Pro and later, which would make Max do nothing.
        configuration.enableAutoDeferredPhotoDelivery = false
        configuration.enableZeroShutterLag = false
        configuration.enableLivePhoto = false
        try await host.camera.configure(configuration)
        // The `.photo` preset doesn't pick the 48MP format by itself.
        await host.camera.setHighResolutionPhotoFormat(true)
    }

    func cameraHostDidConfigure(_ host: CameraPreviewHost) async {
        host.pipeline.activeRenderer = chain
        photoCapture = PRMPhotoCapture(session: host.camera.session)
    }

    func cameraHost(_: CameraPreviewHost, didFailToConfigure error: any Error) {
        snapStatusLabel.text = "Camera unavailable"
        snapButton.isEnabled = false
        toaster.report(error, context: "Camera start")
    }

    func cameraHost(_: CameraPreviewHost, didReceive error: PRMSessionError) {
        toaster.report(error, context: "Camera")
    }
}

// MARK: - LibraryPill

/// A filter in the library; a tap adds it to the chain.
private final class LibraryPill: UIControl {
    var onTap: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = ExampleFont.scaled(12, weight: .semibold, style: .footnote, maximum: 18)
        label.adjustsFontForContentSizeCategory = true
        label.isUserInteractionEnabled = false
        addSubview(label)
        label.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(14)
            $0.centerY.equalToSuperview()
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityHint = "Adds the filter to the chain"
        addAction(UIAction { [weak self] _ in self?.handleTap() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:) instead")
    }

    private func handleTap() {
        if !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.08, animations: { self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }, completion: { _ in
                UIView.animate(withDuration: 0.15) { self.transform = .identity }
            })
        }
        onTap?()
    }
}

// MARK: - ActivePill

/// A filter in the chain: its name and intensity. A tap opens the intensity sheet; the
/// trailing × (or a long press, or VoiceOver's Remove action) removes it.
private final class ActivePill: UIControl {
    // MARK: - Properties

    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    private let title: String
    private let intensityLabel = UILabel()

    // MARK: - Init

    init(title: String, intensity: Float) {
        self.title = title
        super.init(frame: .zero)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.systemYellow.cgColor
        layer.borderWidth = 0.5

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .systemYellow
        titleLabel.font = ExampleFont.scaled(12, weight: .bold, style: .footnote, maximum: 18)
        titleLabel.adjustsFontForContentSizeCategory = true
        intensityLabel.textColor = UIColor.systemYellow.withAlphaComponent(0.75)
        intensityLabel.font = ExampleFont.monospaced(10, weight: .semibold, style: .caption2, maximum: 15)
        intensityLabel.adjustsFontForContentSizeCategory = true
        // The slider glyph tells this pill apart from the library's: it opens a control.
        let knobIcon = UIImageView(image: UIImage(systemName: "slider.horizontal.below.rectangle"))
        knobIcon.tintColor = UIColor.systemYellow.withAlphaComponent(0.75)
        knobIcon.contentMode = .scaleAspectFit
        knobIcon.snp.makeConstraints { $0.size.equalTo(11) }

        let stack = UIStackView(arrangedSubviews: [titleLabel, knobIcon, intensityLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        // A stack view takes touches by default, which would keep them from the pill
        // (a control only tracks touches that hit it, not a subview).
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(14)
            $0.trailing.equalToSuperview().offset(-44)
            $0.centerY.equalToSuperview()
        }

        // The × is a full 44pt square at the trailing end.
        var closeConfiguration = UIButton.Configuration.plain()
        closeConfiguration.image = UIImage(systemName: "xmark.circle.fill")
        closeConfiguration.baseForegroundColor = .systemYellow
        let close = UIButton(configuration: closeConfiguration)
        close.accessibilityLabel = "Remove \(title)"
        close.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .touchUpInside)
        addSubview(close)
        close.snp.makeConstraints {
            $0.trailing.top.bottom.equalToSuperview()
            $0.width.equalTo(44)
        }

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:))))

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityHint = "Opens the intensity slider"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Remove") { [weak self] _ in
                self?.onRemove?()
                return true
            },
        ]
        setIntensity(intensity)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:intensity:) instead")
    }

    // MARK: - Updates

    func setIntensity(_ value: Float) {
        let percent = "\(Int((value * 100).rounded()))%"
        intensityLabel.text = percent
        accessibilityValue = percent
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium, view: self).impactOccurred()
        onRemove?()
    }
}

// MARK: - IntensitySheetViewController

/// The intensity slider for one chain entry, presented as a short sheet.
private final class IntensitySheetViewController: UIViewController {
    // MARK: - Properties

    private let filterName: String
    private let initialIntensity: Float
    private let onChange: (Float) -> Void
    private let valueLabel = UILabel()

    // MARK: - Init

    init(title: String, intensity: Float, onChange: @escaping (Float) -> Void) {
        filterName = title
        initialIntensity = intensity
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:intensity:onChange:) instead")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        let titleLabel = UILabel()
        titleLabel.text = filterName
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        let done = UIButton(configuration: .plain())
        done.configuration?.title = "Done"
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, done])
        header.alignment = .center

        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = initialIntensity
        slider.minimumTrackTintColor = .systemYellow
        slider.accessibilityLabel = "\(filterName) intensity"
        slider.addAction(UIAction { [weak self] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            showValue(slider.value)
            onChange(slider.value)
        }, for: .valueChanged)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        valueLabel.textAlignment = .right
        valueLabel.isAccessibilityElement = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        showValue(initialIntensity)

        let sliderRow = UIStackView(arrangedSubviews: [slider, valueLabel])
        sliderRow.spacing = 12
        sliderRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [header, sliderRow])
        stack.axis = .vertical
        stack.spacing = 12
        view.addSubview(stack)
        stack.snp.makeConstraints {
            $0.top.equalToSuperview().offset(20)
            $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
        }
        done.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
        slider.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    }

    private func showValue(_ value: Float) {
        valueLabel.text = "\(Int((value * 100).rounded()))%"
    }
}
