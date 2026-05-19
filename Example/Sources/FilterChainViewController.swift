import AVFoundation
import CoreImage
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - FilterChainViewController

/// Interactive filter chain editor.
///
/// - Top half: filtered preview.
/// - Bottom half: chain editor (active filters + library to add).
/// - Active filter pills can be reordered (long-press) or removed (swipe to remove).
/// - Tap an active pill to open an intensity slider.
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
    }

    private let catalog: [CatalogEntry] = [
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

    // MARK: - UI

    private let activeStackContainer = UIScrollView()
    private let activeStack = UIStackView()
    private let categorySegmented = UISegmentedControl(items: Category.allCases.map(\.rawValue))
    private let libraryScroll = UIScrollView()
    private let libraryStack = UIStackView()
    private let activeEmptyLabel = UILabel()

    /// In-memory mirror of `chain.entries` to bind to the visual stack.
    private var activeEntries: [(uuid: UUID, name: String, make: @Sendable () -> any PRMFilter, intensity: Float)] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = "Filter Chain"
        setupLayout()
        rebuildLibrary()
        Task { await bootCamera() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await camera.stop() }
    }

    // MARK: - Layout

    private func setupLayout() {
        // Preview — top half
        view.addSubview(previewView)
        previewView.rotation = .rotate90
        previewView.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide)
            $0.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.5)
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

        // Category segmented
        categorySegmented.selectedSegmentIndex = 0
        categorySegmented.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        categorySegmented.selectedSegmentTintColor = .systemYellow
        categorySegmented.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .normal)
        categorySegmented.setTitleTextAttributes([.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .selected)
        categorySegmented.addAction(UIAction { [weak self] _ in self?.rebuildLibrary() }, for: .valueChanged)
        drawer.addSubview(categorySegmented)
        categorySegmented.snp.makeConstraints {
            $0.top.equalTo(activeStackContainer.snp.bottom).offset(16)
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

    // MARK: - Camera boot

    private func bootCamera() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        do {
            try await camera.configure(PRMCameraConfiguration())
        } catch {
            return
        }
        pipeline.activeRenderer = chain
        pipeline.isEnabled = true
        await camera.session.setVideoDataOutputDelegate(pipeline)
        pipeline.onFrame = { [weak self] frame in
            self?.previewView.update(frame.pixelBuffer)
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
    private let intensityIndicator = UIView()
    private var intensity: Float
    private let slider = UISlider()
    private var sliderHost: UIView?

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

        intensityIndicator.backgroundColor = .systemYellow
        intensityIndicator.layer.cornerRadius = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 28)) }

        // Tap → toggle intensity slider sheet.
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        // Long-press → remove with confirmation.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)

        // Trailing × button overlay.
        let close = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        close.tintColor = .systemYellow
        addSubview(close)
        close.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(6)
            $0.centerY.equalToSuperview()
            $0.size.equalTo(14)
        }
        let closeTap = UITapGestureRecognizer(target: self, action: #selector(handleClose))
        close.isUserInteractionEnabled = true
        close.addGestureRecognizer(closeTap)
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
            self?.intensity = new
            self?.onIntensityChanged?(new)
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
