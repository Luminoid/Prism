@preconcurrency import AVFoundation
import CoreMotion
import PrismCore
import SnapKit
import UIKit

// MARK: - ToolbarChip

/// A 44×44 symbol button in Studio's top bar, yellow while its setting is on.
final class ToolbarChip: UIControl {
    // MARK: - Properties

    var onTap: (() -> Void)?

    private let imageView = UIImageView()

    // MARK: - Init

    /// `label` is what VoiceOver reads; set ``setActive(_:)`` / ``setSymbol(_:active:)`` and
    /// `accessibilityValue` as the setting changes.
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        imageView.image = UIImage(systemName: symbol)
        imageView.tintColor = .white
        imageView.contentMode = .center
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }
        snp.makeConstraints { $0.size.equalTo(CGSize(width: 44, height: 44)) }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(symbol:label:) instead")
    }

    // MARK: - Updates

    func setSymbol(_ symbol: String, active: Bool) {
        imageView.image = UIImage(systemName: symbol)
        setActive(active)
    }

    func setActive(_ active: Bool) {
        backgroundColor = active
            ? UIColor.systemYellow.withAlphaComponent(0.25)
            : UIColor.white.withAlphaComponent(0.08)
        imageView.tintColor = active ? .systemYellow : .white
    }
}

// MARK: - TextChip

/// A text pill whose touch target is at least 44×44 while the pill itself stays small: the
/// visible pill is centered in a taller, transparent control. Used for the mode picker, the
/// drawer's ISO AUTO and white-balance preset buttons.
final class TextChip: UIControl {
    // MARK: - Properties

    var onTap: (() -> Void)?

    var title: String {
        didSet {
            label.text = title
            accessibilityLabel = title
        }
    }

    private let pill = UIView()
    private let label = UILabel()
    private var isChipSelected = false
    private var isDimmed = false

    // MARK: - Init

    /// - Parameter pillHeight: The visible pill's height; `nil` sizes it to the text.
    init(title: String, pillHeight: CGFloat? = nil) {
        self.title = title
        super.init(frame: .zero)
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        pill.layer.cornerRadius = 12
        pill.layer.cornerCurve = .continuous
        pill.isUserInteractionEnabled = false
        addSubview(pill)
        label.text = title
        label.textColor = .white
        label.font = ExampleFont.scaled(11, weight: .medium, style: .caption1, maximum: 16)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        pill.addSubview(label)
        pill.snp.makeConstraints {
            $0.leading.trailing.centerY.equalToSuperview()
            $0.top.greaterThanOrEqualToSuperview()
            if let pillHeight {
                $0.height.equalTo(pillHeight)
            }
        }
        label.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(8)
            $0.centerY.equalToSuperview()
            if pillHeight == nil {
                $0.top.bottom.equalToSuperview().inset(6)
            } else {
                $0.top.greaterThanOrEqualToSuperview().offset(2)
            }
        }
        snp.makeConstraints {
            $0.height.greaterThanOrEqualTo(44)
            $0.height.equalTo(44).priority(.low)
            $0.width.greaterThanOrEqualTo(44)
        }
        isAccessibilityElement = true
        accessibilityLabel = title
        applyStyle()
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:pillHeight:) instead")
    }

    // MARK: - Updates

    /// Selected pills are solid yellow; dimmed ones (a mode the configuration excludes) fade
    /// but still take taps, so the picker can explain why.
    func setAppearance(selected: Bool, dimmed: Bool) {
        isChipSelected = selected
        isDimmed = dimmed
        applyStyle()
    }

    private func applyStyle() {
        pill.backgroundColor = isChipSelected ? .systemYellow : UIColor.white.withAlphaComponent(0.10)
        label.textColor = isChipSelected ? .black : .white
        alpha = isDimmed ? 0.35 : 1
        var traits: UIAccessibilityTraits = .button
        if isChipSelected { traits.insert(.selected) }
        if isDimmed { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }
}

// MARK: - LensPill

/// A focal-length chip in Studio's lens strip ("13mm", "24mm", "120mm"). The capsule is drawn
/// inside a control at least 44pt tall; sensor-crop chips (the 2× crop of a 48MP main
/// sensor) get a dashed outline.
final class LensPill: UIControl {
    // MARK: - Properties

    var onTap: (() -> Void)?

    /// The raw zoom factor this pill activates. The highest-zoom pill whose factor is at or
    /// below the current zoom is the one feeding frames when AVFoundation doesn't report the
    /// active constituent.
    let zoomFactor: CGFloat

    /// The physical constituent lens this pill represents, matched against
    /// `PRMCameraState.activePrimaryDeviceType` so the highlight follows the lens AVFoundation
    /// actually uses (low light can keep the wide lens at 5×).
    let deviceType: AVCaptureDevice.DeviceType?

    /// A real lens, or a sensor crop. Crops don't trigger the lens-switch overlay because the
    /// physical lens doesn't change.
    let kind: PRMLens.Kind

    private(set) var isActive = false

    private let capsule = UIView()
    private let label = UILabel()
    /// Drawn as a shape layer because `CALayer.borderWidth` can't dash.
    private let borderShape = CAShapeLayer()

    // MARK: - Init

    init(title: String, zoomFactor: CGFloat, deviceType: AVCaptureDevice.DeviceType?, kind: PRMLens.Kind) {
        self.zoomFactor = zoomFactor
        self.deviceType = deviceType
        self.kind = kind
        super.init(frame: .zero)
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        capsule.layer.cornerCurve = .continuous
        capsule.isUserInteractionEnabled = false
        borderShape.fillColor = nil
        borderShape.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        borderShape.lineWidth = 0.5
        if kind == .nativeResolutionCrop {
            borderShape.lineDashPattern = [4, 3]
        }
        capsule.layer.addSublayer(borderShape)
        addSubview(capsule)
        label.text = title
        label.textColor = .white
        label.font = ExampleFont.monospaced(11, weight: .bold, style: .caption1, maximum: 15)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        capsule.addSubview(label)
        capsule.snp.makeConstraints {
            $0.leading.trailing.centerY.equalToSuperview()
            $0.top.greaterThanOrEqualToSuperview()
        }
        label.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)) }
        snp.makeConstraints {
            $0.height.greaterThanOrEqualTo(44)
            $0.height.equalTo(44).priority(.low)
            $0.width.greaterThanOrEqualTo(44)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = kind == .nativeResolutionCrop ? "\(title) crop" : "\(title) lens"
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:zoomFactor:deviceType:kind:) instead")
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = capsule.bounds.height / 2
        capsule.layer.cornerRadius = radius
        // Inset by half the stroke so it sits on the capsule's edge instead of half-clipped.
        let inset = borderShape.lineWidth / 2
        let rect = capsule.bounds.insetBy(dx: inset, dy: inset)
        borderShape.path = UIBezierPath(roundedRect: rect, cornerRadius: max(0, radius - inset)).cgPath
    }

    // MARK: - Updates

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        // Both states stay dark enough to read over the live preview.
        capsule.backgroundColor = active
            ? UIColor.systemYellow.withAlphaComponent(0.25)
            : UIColor.black.withAlphaComponent(0.45)
        borderShape.strokeColor = (active
            ? UIColor.systemYellow.withAlphaComponent(0.85)
            : UIColor.white.withAlphaComponent(0.25)).cgColor
        label.textColor = active ? .systemYellow : .white
        accessibilityTraits = active ? [.button, .selected] : .button
    }
}

// MARK: - CapturePill

/// The pill over the preview while a capture is in flight: "LIVE" while a Live Photo's
/// paired movie records, "NIGHT n/total" while a Night stack exposes. Its opacity pulses
/// unless Reduce Motion is on.
final class CapturePill: UIView {
    // MARK: - Properties

    private static let pulseKey = "pulse"

    private let icon = UIImageView()
    private let label = UILabel()

    // MARK: - Init

    init(symbol: String, tint: UIColor, textColor: UIColor) {
        super.init(frame: .zero)
        backgroundColor = tint.withAlphaComponent(0.95)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.tintColor = textColor
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.textColor = textColor
        label.font = ExampleFont.scaled(11, weight: .heavy, style: .caption1, maximum: 16)
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)) }
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(symbol:tint:textColor:) instead")
    }

    // MARK: - Updates

    /// Shows the pill with `text`, or hides it. Updating the text while it's showing keeps the
    /// pulse running instead of restarting it.
    func setActive(_ active: Bool, text: String? = nil) {
        guard active else {
            layer.removeAnimation(forKey: Self.pulseKey)
            isHidden = true
            return
        }
        if let text {
            label.text = text
            accessibilityLabel = text
        }
        isHidden = false
        guard layer.animation(forKey: Self.pulseKey) == nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }
}

// MARK: - StatusPill

/// A steady pill over the preview for a mode's status: Portrait's yellow "NATURAL LIGHT" when
/// the depth effect will apply, or a hint such as "Move farther away." in a dark pill. Unlike
/// ``CapturePill`` it doesn't pulse.
final class StatusPill: UIView {
    enum Style {
        case highlight
        case hint
    }

    // MARK: - Properties

    private let label = UILabel()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.font = ExampleFont.scaled(11, weight: .heavy, style: .caption1, maximum: 16)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        addSubview(label)
        label.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)) }
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init() instead")
    }

    // MARK: - Updates

    func show(_ text: String, style: Style) {
        label.text = text
        accessibilityLabel = text
        switch style {
        case .highlight:
            backgroundColor = .systemYellow
            label.textColor = .black
        case .hint:
            backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.textColor = .white
        }
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}

// MARK: - ModePillStrip

/// One horizontally scrolling row of mode pills. Rows are 44pt tall, so every pill is a full
/// touch target; the visible pills are shorter.
final class ModePillStrip: UIView {
    // MARK: - Properties

    var onSelect: ((Int) -> Void)?
    var onDisabledTap: ((String) -> Void)?
    var selectedIndex = 0 {
        didSet { applySelection() }
    }

    private let pillHeight: CGFloat
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var pills: [TextChip] = []
    private var disabledMessages: [Int: String] = [:]

    // MARK: - Init

    init(pillHeight: CGFloat) {
        self.pillHeight = pillHeight
        super.init(frame: .zero)
        addSubview(scrollView)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
        scrollView.addSubview(stackView)
        stackView.axis = .horizontal
        stackView.spacing = 4
        // Centered in the frame while the pills fit; wider than the frame, the content layout
        // guide grows and the row scrolls.
        stackView.snp.makeConstraints {
            $0.top.bottom.equalTo(scrollView.contentLayoutGuide)
            $0.leading.greaterThanOrEqualTo(scrollView.contentLayoutGuide)
            $0.trailing.lessThanOrEqualTo(scrollView.contentLayoutGuide)
            $0.centerX.equalTo(scrollView.frameLayoutGuide)
            $0.height.equalTo(scrollView.frameLayoutGuide)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(pillHeight:) instead")
    }

    // MARK: - Updates

    func setModes(_ labels: [String]) {
        for pill in pills {
            pill.removeFromSuperview()
        }
        pills = []
        disabledMessages.removeAll()
        for (index, label) in labels.enumerated() {
            let pill = TextChip(title: label, pillHeight: pillHeight)
            pill.onTap = { [weak self] in
                guard let self else { return }
                if let message = disabledMessages[index] {
                    onDisabledTap?(message)
                    return
                }
                selectedIndex = index
                onSelect?(index)
            }
            pills.append(pill)
            stackView.addArrangedSubview(pill)
        }
        applySelection()
    }

    /// Replaces one pill's text without rebuilding the row (Night AUTO shows its resolved
    /// duration).
    func setLabel(at index: Int, to text: String) {
        guard pills.indices.contains(index) else { return }
        pills[index].title = text
    }

    /// Dims a pill and routes its taps to `onDisabledTap` with `message`; `nil` re-enables it.
    func setDisabled(at index: Int, message: String?) {
        guard pills.indices.contains(index) else { return }
        disabledMessages[index] = message
        applySelection()
    }

    private func applySelection() {
        for (index, pill) in pills.enumerated() {
            pill.setAppearance(selected: index == selectedIndex, dimmed: disabledMessages[index] != nil)
        }
    }
}

// MARK: - ModePicker

/// Two-row capture-mode picker: the capture style on top, its variants underneath.
///
/// PHOTO offers STANDARD / LIVE / PORTRAIT / BURST, VIDEO offers 24 / 30 and SLO-MO (when a
/// camera supports 120 fps), NIGHT offers AUTO / 1s / 3s / 5s.
final class ModePicker: UIView {
    // MARK: - Types

    enum Primary: CaseIterable, Equatable {
        case photo, video, night

        var label: String {
            switch self {
            case .photo: "PHOTO"
            case .video: "VIDEO"
            case .night: "NIGHT"
            }
        }
    }

    enum Variant: Equatable {
        case standard, live, portrait, burst
        case video24, video30, slowMo
        case nightAuto, night1s, night3s, night5s

        var label: String {
            switch self {
            case .standard: "STANDARD"
            case .live: "LIVE"
            case .portrait: "PORTRAIT"
            case .burst: "BURST"
            case .video24: "24"
            case .video30: "30"
            case .slowMo: "SLO-MO"
            case .nightAuto: "AUTO"
            case .night1s: "1s"
            case .night3s: "3s"
            case .night5s: "5s"
            }
        }
    }

    // MARK: - Properties

    var onChange: ((Primary, Variant) -> Void)?
    var onDisabledVariantTap: ((String) -> Void)?

    /// Whether VIDEO offers SLO-MO. Studio sets it from the current camera position.
    var supportsSlowMotion = false {
        didSet { rebuildVariants() }
    }

    private(set) var primary: Primary = .photo
    private(set) var variant: Variant = .standard

    private let primaryRow = ModePillStrip(pillHeight: 34)
    private let variantRow = ModePillStrip(pillHeight: 28)

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [primaryRow, variantRow])
        stack.axis = .vertical
        stack.alignment = .fill
        addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
        primaryRow.snp.makeConstraints { $0.height.equalTo(44) }
        variantRow.snp.makeConstraints { $0.height.equalTo(44) }

        primaryRow.setModes(Primary.allCases.map(\.label))
        primaryRow.onSelect = { [weak self] index in
            guard let self, Primary.allCases.indices.contains(index) else { return }
            primary = Primary.allCases[index]
            // Each style's default: STANDARD, 30 fps (the system Camera's default), AUTO.
            variant = switch primary {
            case .photo: .standard
            case .video: .video30
            case .night: .nightAuto
            }
            rebuildVariants()
            onChange?(primary, variant)
        }
        variantRow.onSelect = { [weak self] index in
            guard let self else { return }
            let variants = variants(for: primary)
            guard variants.indices.contains(index) else { return }
            variant = variants[index]
            onChange?(primary, variant)
        }
        variantRow.onDisabledTap = { [weak self] message in
            self?.onDisabledVariantTap?(message)
        }
        rebuildVariants()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init() instead")
    }

    // MARK: - Updates

    /// Dims a variant pill and routes its taps to `onDisabledVariantTap`; `nil` clears it.
    /// No-op when the current style doesn't offer `variant`.
    func setVariantDisabled(_ variant: Variant, message: String?) {
        guard let index = variants(for: primary).firstIndex(of: variant) else { return }
        variantRow.setDisabled(at: index, message: message)
    }

    /// Replaces one variant pill's text (Night AUTO shows "AUTO 3s") without changing the
    /// variant it selects.
    func setVariantLabel(for variant: Variant, to text: String) {
        guard let index = variants(for: primary).firstIndex(of: variant) else { return }
        variantRow.setLabel(at: index, to: text)
    }

    /// Selects a (style, variant) pair without firing `onChange`: Studio uses it to move the
    /// picker when a setting excludes the current mode, or after a camera flip. Falls back to
    /// the style's first variant when it doesn't offer `variant`.
    func select(primary: Primary, variant: Variant) {
        guard let primaryIndex = Primary.allCases.firstIndex(of: primary) else { return }
        primaryRow.selectedIndex = primaryIndex
        self.primary = primary
        self.variant = variant
        rebuildVariants()
    }

    private func variants(for primary: Primary) -> [Variant] {
        switch primary {
        case .photo: [.standard, .live, .portrait, .burst]
        // 60 fps and up would force a 16:9 video format (see `StudioViewController.VideoFPS`);
        // slow motion is its own variant when the camera supports it.
        case .video: supportsSlowMotion ? [.video24, .video30, .slowMo] : [.video24, .video30]
        case .night: [.nightAuto, .night1s, .night3s, .night5s]
        }
    }

    private func rebuildVariants() {
        let variants = variants(for: primary)
        variantRow.setModes(variants.map(\.label))
        let index = variants.firstIndex(of: variant) ?? 0
        variantRow.selectedIndex = index
        variant = variants[index]
    }
}

// MARK: - StabilityMeter

/// Whether the phone is held still enough for Night's longer frames (braced or on a tripod):
/// the gyroscope's rotation rate has stayed under 0.05 rad/s for 0.7 s. Reads the shared
/// motion manager ten times a second while running, starting pull updates if nobody else has.
@MainActor
final class StabilityMeter {
    private let motionManager: CMMotionManager
    private var task: Task<Void, Never>?
    private var startedUpdates = false
    private var stillSince: Date?
    private(set) var isStable = false

    init(motionManager: CMMotionManager) {
        self.motionManager = motionManager
    }

    func start() {
        #if !targetEnvironment(simulator)
            guard task == nil, motionManager.isDeviceMotionAvailable else { return }
            if !motionManager.isDeviceMotionActive {
                motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
                motionManager.startDeviceMotionUpdates()
                startedUpdates = true
            }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        #endif
    }

    func stop() {
        task?.cancel()
        task = nil
        if startedUpdates {
            motionManager.stopDeviceMotionUpdates()
            startedUpdates = false
        }
        stillSince = nil
        isStable = false
    }

    private func sample() {
        guard let rate = motionManager.deviceMotion?.rotationRate else { return }
        let magnitude = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
        guard magnitude < 0.05 else {
            stillSince = nil
            isStable = false
            return
        }
        let since = stillSince ?? Date()
        stillSince = since
        isStable = Date().timeIntervalSince(since) >= 0.7
    }
}
