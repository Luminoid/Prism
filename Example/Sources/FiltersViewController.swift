import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - FiltersViewController

/// Demonstrates ALL 15 built-in filters + 3 custom filters, `PRMBasicFilterRenderer`,
/// `PRMFilterChain` (full API), and `PRMCameraFilterRenderer` protocol.
///
/// Two modes via segmented control: **Gallery** (browse single filters by category)
/// and **Chain Builder** (compose multi-filter stacks with intensity control).
final class FiltersViewController: UIViewController {
    // MARK: - Mode

    private enum Mode {
        case gallery
        case chain
    }

    // MARK: - Properties

    private let sessionManager = PRMCameraSessionManager()
    private let filterPipeline = PRMFilterPipeline()
    private let previewView = PRMPreviewMetalView(frame: .zero)
    private let captureButton = PRMCameraButton()

    private let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.PrismExample.FilterOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )

    private var mode: Mode = .gallery

    // Gallery state
    private var selectedCategory: FilterCategory = .custom
    private var selectedFilterIndex: Int? // nil = no filter (pass-through)
    private let categorySegmented = UISegmentedControl(
        items: FilterCategory.allCases.map(\.rawValue),
    )
    private let filterCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 100, height: 60)
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        return cv
    }()

    private let filterInfoLabel = UILabel()

    // Chain state
    private var chainEntries: [(entry: ExampleFilterCatalog.Entry, intensity: Float)] = []
    private let chainTableView = UITableView(frame: .zero, style: .plain)
    private let chainInfoLabel = UILabel()

    // Shared controls
    private let modeSegmented = UISegmentedControl(items: ["Gallery", "Chain Builder"])
    private let galleryContainer = UIView()
    private let chainContainer = UIView()

    /// Current filter for capture
    private var currentFilter: (any PRMCameraFilter)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Filters"
        view.backgroundColor = .black
        setupUI()
        setupCamera()
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
        // Preview
        view.addSubview(previewView)
        previewView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.equalToSuperview().multipliedBy(0.5)
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

        // Mode selector
        modeSegmented.selectedSegmentIndex = 0
        modeSegmented.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        // Controls area
        let controlsStack = UIStackView()
        controlsStack.axis = .vertical
        controlsStack.spacing = 8
        view.addSubview(controlsStack)
        controlsStack.snp.makeConstraints {
            $0.top.equalTo(previewView.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(8)
            $0.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        controlsStack.addArrangedSubview(modeSegmented)
        setupGalleryUI(in: controlsStack)
        setupChainUI(in: controlsStack)

        chainContainer.isHidden = true
    }

    // MARK: - Gallery UI

    private func setupGalleryUI(in stack: UIStackView) {
        galleryContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        categorySegmented.selectedSegmentIndex = 0
        categorySegmented.addTarget(self, action: #selector(categoryChanged), for: .valueChanged)

        filterCollectionView.register(FilterCell.self, forCellWithReuseIdentifier: "FilterCell")
        filterCollectionView.dataSource = self
        filterCollectionView.delegate = self

        filterInfoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        filterInfoLabel.textColor = .secondaryLabel
        filterInfoLabel.numberOfLines = 0
        filterInfoLabel.text = "No filter (pass-through)"

        let innerStack = UIStackView(arrangedSubviews: [categorySegmented, filterCollectionView, filterInfoLabel])
        innerStack.axis = .vertical
        innerStack.spacing = 8

        filterCollectionView.snp.makeConstraints { $0.height.equalTo(68) }

        galleryContainer.addSubview(innerStack)
        innerStack.snp.makeConstraints { $0.edges.equalToSuperview() }

        stack.addArrangedSubview(galleryContainer)
    }

    // MARK: - Chain UI

    private func setupChainUI(in stack: UIStackView) {
        chainInfoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        chainInfoLabel.textColor = .secondaryLabel
        chainInfoLabel.text = "Filters: 0 | Tap + to add"

        chainTableView.register(ChainCell.self, forCellReuseIdentifier: "ChainCell")
        chainTableView.dataSource = self
        chainTableView.delegate = self
        chainTableView.rowHeight = 52
        chainTableView.backgroundColor = .clear

        let addButton = UIButton(type: .system)
        addButton.setTitle("+ Add Filter", for: .normal)
        addButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        addButton.addTarget(self, action: #selector(addFilterToChain), for: .touchUpInside)

        let clearButton = UIButton(type: .system)
        clearButton.setTitle("Clear All", for: .normal)
        clearButton.tintColor = .systemRed
        clearButton.addTarget(self, action: #selector(clearChain), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [addButton, clearButton])
        buttonRow.spacing = 16

        let innerStack = UIStackView(arrangedSubviews: [chainInfoLabel, chainTableView, buttonRow])
        innerStack.axis = .vertical
        innerStack.spacing = 8

        chainContainer.addSubview(innerStack)
        innerStack.snp.makeConstraints { $0.edges.equalToSuperview() }

        stack.addArrangedSubview(chainContainer)
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
                with: PRMCameraConfiguration(includesAudio: false),
                videoDataOutputDelegate: pipeline,
                videoDataOutputQueue: outputQueue,
            )
            pipeline.isRenderingEnabled = true
            DispatchQueue.main.async { preview.rotation = .rotate90Degrees }
        }
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        mode = modeSegmented.selectedSegmentIndex == 0 ? .gallery : .chain
        galleryContainer.isHidden = mode == .chain
        chainContainer.isHidden = mode == .gallery

        // Apply current mode's filter
        if mode == .gallery {
            applyGalleryFilter()
        } else {
            rebuildChain()
        }
    }

    @objc private func categoryChanged() {
        let categories = FilterCategory.allCases
        selectedCategory = categories[categorySegmented.selectedSegmentIndex]
        selectedFilterIndex = nil
        filterCollectionView.reloadData()
        applyGalleryFilter()
    }

    // MARK: - Gallery Filter Application

    private func applyGalleryFilter() {
        let entries = ExampleFilterCatalog.entries(for: selectedCategory)

        guard let index = selectedFilterIndex, index < entries.count else {
            // No filter
            dataOutputQueue.sync {
                filterPipeline.isRenderingEnabled = false
                filterPipeline.activeRenderer = nil
                filterPipeline.isRenderingEnabled = true
            }
            currentFilter = nil
            filterInfoLabel.text = "No filter (pass-through)"
            return
        }

        let entry = entries[index]
        let renderer = entry.makeRenderer()
        dataOutputQueue.sync {
            filterPipeline.isRenderingEnabled = false
            filterPipeline.activeRenderer = renderer
            filterPipeline.isRenderingEnabled = true
        }
        currentFilter = entry.makeFilter()
        filterInfoLabel.text = "\(entry.name) | \(entry.parameters) | Prepared: \(renderer.isPrepared)"
    }

    // MARK: - Chain

    @objc private func addFilterToChain() {
        let alert = UIAlertController(title: "Add Filter", message: nil, preferredStyle: .actionSheet)
        for entry in ExampleFilterCatalog.all {
            alert.addAction(UIAlertAction(title: "\(entry.name) (\(entry.category.rawValue))", style: .default) { [weak self] _ in
                self?.chainEntries.append((entry: entry, intensity: 1.0))
                self?.chainTableView.reloadData()
                self?.rebuildChain()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }

    @objc private func clearChain() {
        chainEntries.removeAll()
        chainTableView.reloadData()
        rebuildChain()
    }

    private func rebuildChain() {
        let filterEntries = chainEntries.map { item in
            PRMFilterChain.FilterEntry(filter: item.entry.makeFilter(), intensity: item.intensity)
        }

        if filterEntries.isEmpty {
            dataOutputQueue.sync {
                filterPipeline.isRenderingEnabled = false
                filterPipeline.activeRenderer = nil
                filterPipeline.isRenderingEnabled = true
            }
            currentFilter = nil
            chainInfoLabel.text = "Filters: 0 | Tap + to add"
            return
        }

        let chain = PRMFilterChain(description: "User Chain", filters: filterEntries)
        dataOutputQueue.sync {
            filterPipeline.isRenderingEnabled = false
            filterPipeline.activeRenderer = chain
            filterPipeline.isRenderingEnabled = true
        }

        // For capture, build a simple sequential filter
        currentFilter = ChainCaptureFilter(entries: chainEntries.map { ($0.entry.makeFilter(), $0.intensity) })
        chainInfoLabel.text = "Filters: \(chainEntries.count) | Prepared: \(chain.isPrepared)"
    }

    // MARK: - Capture

    private func handleCapture() {
        CaptureHelper.captureAndSave(
            sessionManager: sessionManager,
            filter: currentFilter,
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

// MARK: - UICollectionView (Gallery)

extension FiltersViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        ExampleFilterCatalog.entries(for: selectedCategory).count + 1 // +1 for "None"
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FilterCell", for: indexPath) as? FilterCell else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: "FilterCell", for: indexPath)
        }
        let entries = ExampleFilterCatalog.entries(for: selectedCategory)

        if indexPath.item == 0 {
            cell.configure(name: "None", detail: "pass-through", isSelected: selectedFilterIndex == nil)
        } else {
            let entry = entries[indexPath.item - 1]
            let isSelected = selectedFilterIndex == indexPath.item - 1
            cell.configure(name: entry.name, detail: entry.parameters, isSelected: isSelected)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item == 0 {
            selectedFilterIndex = nil
        } else {
            selectedFilterIndex = indexPath.item - 1
        }
        collectionView.reloadData()
        applyGalleryFilter()
    }
}

// MARK: - UITableView (Chain Builder)

extension FiltersViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        chainEntries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "ChainCell", for: indexPath) as? ChainCell else {
            return tableView.dequeueReusableCell(withIdentifier: "ChainCell", for: indexPath)
        }
        let item = chainEntries[indexPath.row]
        cell.configure(name: item.entry.name, intensity: item.intensity, adjustable: item.entry.adjustable) { [weak self] newIntensity in
            self?.chainEntries[indexPath.row].intensity = newIntensity
            self?.rebuildChain()
        }
        return cell
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath,
    ) {
        if editingStyle == .delete {
            chainEntries.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            rebuildChain()
        }
    }
}

// MARK: - FilterCell

private final class FilterCell: UICollectionViewCell {
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.separator.cgColor

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 2

        contentView.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(4) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(name: String, detail: String, isSelected: Bool) {
        nameLabel.text = name
        detailLabel.text = detail
        contentView.backgroundColor = isSelected
            ? UIColor.systemBlue.withAlphaComponent(0.3)
            : UIColor.white.withAlphaComponent(0.1)
        contentView.layer.borderColor = isSelected
            ? UIColor.systemBlue.cgColor
            : UIColor.separator.cgColor
    }
}

// MARK: - ChainCell

private final class ChainCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let slider = UISlider()
    private let intensityLabel = UILabel()
    private var onChange: ((Float) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white

        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        intensityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        intensityLabel.textColor = .secondaryLabel
        intensityLabel.textAlignment = .right

        let row = UIStackView(arrangedSubviews: [nameLabel, slider, intensityLabel])
        row.spacing = 8

        nameLabel.snp.makeConstraints { $0.width.equalTo(80) }
        intensityLabel.snp.makeConstraints { $0.width.equalTo(36) }

        contentView.addSubview(row)
        row.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(name: String, intensity: Float, adjustable: Bool = true, onChange: @escaping (Float) -> Void) {
        nameLabel.text = name
        slider.value = intensity
        slider.isHidden = !adjustable
        if adjustable {
            intensityLabel.text = String(format: "%.1f", intensity)
        } else {
            intensityLabel.text = "1.0"
        }
        self.onChange = onChange
    }

    @objc private func sliderChanged() {
        intensityLabel.text = String(format: "%.1f", slider.value)
        onChange?(slider.value)
    }
}

// MARK: - ChainCaptureFilter

/// Applies a chain of filters sequentially for still photo capture.
private final class ChainCaptureFilter: PRMCameraFilter, @unchecked Sendable {
    private let filters: [(filter: any PRMCameraFilter, intensity: Float)]

    init(entries: [(any PRMCameraFilter, Float)]) {
        self.filters = entries.map { (filter: $0.0, intensity: $0.1) }
    }

    func render(image: CIImage) -> CIImage? {
        var result = image
        for entry in filters {
            guard let filtered = entry.filter.render(image: result) else { continue }
            if entry.intensity >= 1.0 {
                result = filtered
            } else {
                // Blend original and filtered by intensity
                let blended = filtered.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: CIImage(color: CIColor(red: CGFloat(entry.intensity),
                                                                 green: CGFloat(entry.intensity),
                                                                 blue: CGFloat(entry.intensity)))
                        .cropped(to: result.extent),
                ])
                result = blended
            }
        }
        return result
    }
}
