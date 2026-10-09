@preconcurrency import AVFoundation
import PrismCore
import PrismUI
import UIKit

// MARK: - ModernCaptureControls

/// Studio's drawer sections, telemetry badges and overlays for the iOS 26 / 27 capture
/// features: priority modes (with the locked value) and variable aperture, aperture pacing,
/// exposure signals, lens lock, rect focus, object detection and subject tracking, smudge
/// detection, low-light noise reduction, Cinematic Video (tap styles, depth aperture,
/// metadata capture), dynamic aspect ratio + Smart Framing, and AirPods Camera Control
/// sounds.
///
/// Rows a device or OS can't support stay in the drawer but are disabled; tapping one
/// explains why (via the toast), which makes hardware coverage visible while testing.
/// Studio rebuilds the sections when the camera flips; between rebuilds (the hops between the
/// virtual and wide cameras, which mustn't pull a slider out from under the finger)
/// availability is re-checked in place whenever the device changes, and ``sync(from:)``
/// mirrors device state back into the rows.
@MainActor
final class ModernCaptureControls {
    // MARK: - Types

    /// What a tap does while Cinematic Video is on. A tap on a detected face or body tracks
    /// that object, except in `.fixed`.
    private enum CinematicTapStyle {
        case strong, weak, fixed
    }

    // MARK: - Properties

    private let camera: PRMCamera
    private let captureEventHelper: PRMCaptureEventHelper
    private let toast: (String) -> Void
    /// Studio's conflict rule before a setting turns on (``StudioViewController/prepare(for:)``):
    /// it turns off what conflicts and, for manual exposure, hops to the single wide camera
    /// (virtual devices reject locked exposure axes). `false` refuses the change.
    private let prepare: (StudioSetting) async -> Bool
    /// The hop back to the virtual camera once everything is auto again.
    private let didReturnToAutoExposure: () async -> Void
    /// Studio's refresh after a control changed cameras (Cinematic Video's switch to the
    /// camera that runs it): rotation, lens strip, drawer ranges.
    private let cameraDidChange: () async -> Void

    /// Per-row availability, re-evaluated when the device changes.
    private var availabilityChecks: [(row: PRMSettingsRow, reason: (PRMCameraDevice) -> String?)] = []
    /// Rows that also depend on the session (a recording, Subject Tracking), re-evaluated on
    /// every state tick after the device check, which wins.
    private var stateChecks: [(row: PRMSettingsRow, reason: (PRMCameraState, Bool) -> String?)] = []
    private var lastCheckedDevice: PRMCameraDevice?

    /// When on, tap-to-focus meters a rect twice the system default instead of a point.
    private(set) var usesRectFocus = false
    /// Mirrors `PRMCameraState.isContinuousAutoFocusTrackingEnabled`.
    private(set) var isTrackingEnabled = false
    private var isCinematicVideoEnabled = false
    private var cinematicTapStyle: CinematicTapStyle = .strong
    private var enabledSignals: Set<PRMExposureSignal>?
    private var latestFraming: PRMFraming?
    /// Latest detections, for hit-testing Cinematic Video taps against faces and bodies.
    private var latestObjects: [PRMDetectedObject] = []
    private var isDetectingObjects = false
    /// AirPods Camera Control: the custom-sound toggle, and whether the shutter currently
    /// takes a still, starts a recording or stops one.
    private var usesCustomSounds = false
    private var captureSoundContext = (isVideoMode: false, isRecording: false)
    /// Controls whose change is still being applied; ``sync(from:)`` leaves them alone so a
    /// state tick from before the change lands can't flip them back. The generation keeps an
    /// older change that finishes late from clearing a newer one's mark.
    private var pendingControls: Set<String> = []
    private var pendingGenerations: [String: Int] = [:]

    private var detectedObjectsTask: Task<Void, Never>?
    private var framingTask: Task<Void, Never>?
    /// Camera calls from the rows, latest wins per control.
    private let runner = LatestWinsRunner()

    private weak var previewView: PRMPreviewView?
    private let trackingOverlay = TrackedSubjectOverlay()
    /// Thin outlines around every detected face, body or pet.
    private let detectionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.lineWidth = 1
        return layer
    }()

    // Rows and controls that `sync(from:)` keeps in step with the device.
    private weak var priorityControl: UISegmentedControl?
    private weak var priorityValueSlider: UISlider?
    private weak var priorityRow: PRMSettingsRow?
    private weak var apertureSlider: UISlider?
    private weak var signalsRow: PRMSettingsRow?
    private weak var trackingSwitch: UISwitch?
    private weak var trackingBiasSlider: UISlider?
    private weak var trackingBiasRow: PRMSettingsRow?
    private weak var smudgeSwitch: UISwitch?
    private weak var smudgeRow: PRMSettingsRow?
    private weak var noiseReductionRow: PRMSettingsRow?
    private var noiseReductionLabel = "auto"
    private weak var cinematicSwitch: UISwitch?
    private weak var cinematicRow: PRMSettingsRow?
    private weak var simulatedApertureSlider: UISlider?
    private weak var simulatedApertureRow: PRMSettingsRow?
    private weak var cinematicMetadataRow: PRMSettingsRow?
    private var cinematicMetadataLabel = "auto"
    private weak var lensLockControl: UISegmentedControl?
    private weak var lensLockRow: PRMSettingsRow?
    private weak var aspectControl: UISegmentedControl?
    private weak var aspectRow: PRMSettingsRow?
    private var aspectRatios: [PRMAspectRatio] = []

    // MARK: - Init

    init(
        camera: PRMCamera,
        captureEventHelper: PRMCaptureEventHelper,
        toast: @escaping (String) -> Void,
        prepare: @escaping (StudioSetting) async -> Bool,
        didReturnToAutoExposure: @escaping () async -> Void,
        cameraDidChange: @escaping () async -> Void
    ) {
        self.camera = camera
        self.captureEventHelper = captureEventHelper
        self.toast = toast
        self.prepare = prepare
        self.didReturnToAutoExposure = didReturnToAutoExposure
        self.cameraDidChange = cameraDidChange
        usesCustomSounds = PRMCaptureEventHelper.usesCustomCaptureSounds
        applyCaptureSounds()
    }

    deinit {
        detectedObjectsTask?.cancel()
        framingTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Installs the overlays and subscribes to detections and Smart Framing.
    func start(previewView: PRMPreviewView) {
        self.previewView = previewView
        if detectionLayer.superlayer == nil {
            previewView.layer.addSublayer(detectionLayer)
        }
        if trackingOverlay.superview == nil {
            previewView.addSubview(trackingOverlay)
        }
        detectedObjectsTask?.cancel()
        detectedObjectsTask = Task { [weak self, camera] in
            for await objects in camera.detectedObjectsStream() {
                self?.showDetections(objects)
            }
        }
        framingTask?.cancel()
        framingTask = Task { [weak self, camera] in
            for await framing in camera.framingRecommendationStream() {
                self?.latestFraming = framing
            }
        }
    }

    func stop() {
        detectedObjectsTask?.cancel()
        framingTask?.cancel()
        detectedObjectsTask = nil
        framingTask = nil
        runner.cancelAll()
        pendingControls.removeAll()
        clearDetections()
    }

    /// Runs a control's change with `sync(from:)` paused for that control until it lands.
    private func applyPending(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        let generation = (pendingGenerations[key] ?? 0) + 1
        pendingGenerations[key] = generation
        pendingControls.insert(key)
        runner.run(key) { [weak self] in
            await body()
            guard let self, pendingGenerations[key] == generation else { return }
            pendingControls.remove(key)
        }
    }

    // MARK: - Focus

    /// Tap-to-focus at a device point. With Cinematic Video on, a tap on a detected face or
    /// body tracks it, and the weak / fixed tap styles send their own focus request.
    /// Otherwise: continuous AF while tracking (that engages it), and a rect twice the
    /// default size when rect focus is on. Under a manual exposure (custom, a priority mode,
    /// locked) the tap focuses only, so the ISO and shutter the user set stay.
    func focus(atDevicePoint point: CGPoint) async {
        if isCinematicVideoEnabled, let request = cinematicFocusRequest(at: point) {
            await camera.setCinematicFocus(request)
            return
        }
        let focusMode: AVCaptureDevice.FocusMode = isTrackingEnabled ? .continuousAutoFocus : .autoFocus
        let exposure = camera.state.exposureMode
        let exposureMode: AVCaptureDevice.ExposureMode? = exposure == .custom || exposure == .locked ? nil : .autoExpose
        if usesRectFocus, let base = await camera.defaultFocusRect(for: point) {
            let rect = base.insetBy(dx: -base.width / 2, dy: -base.height / 2)
            await camera.setFocusAndExposure(focusMode: focusMode, exposureMode: exposureMode, in: rect, monitorSubjectAreaChange: true)
        } else {
            await camera.setFocusAndExposure(focusMode: focusMode, exposureMode: exposureMode, at: point, monitorSubjectAreaChange: true)
        }
    }

    /// `nil` leaves the default (a strong track at the point) to `setFocusAndExposure`, which
    /// also meters there; the other requests change focus only.
    private func cinematicFocusRequest(at point: CGPoint) -> PRMCinematicFocusRequest? {
        let mode: PRMCinematicFocusMode = cinematicTapStyle == .weak ? .weak : .strong
        if cinematicTapStyle != .fixed, let id = trackableObject(at: point)?.objectID {
            return .trackObject(id: id, mode: mode)
        }
        switch cinematicTapStyle {
        case .strong: return nil
        case .weak: return .trackPoint(point, mode: .weak)
        case .fixed: return .fixedPoint(point, mode: .strong)
        }
    }

    /// The smallest detected object with an identifier under the point (a face wins over
    /// the body around it).
    private func trackableObject(at point: CGPoint) -> PRMDetectedObject? {
        latestObjects
            .filter { $0.objectID != nil && $0.bounds.contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    // MARK: - Capture sounds

    /// Studio calls this when the capture mode or recording state changes, so an AirPods
    /// stem click plays the matching sound: the shutter for stills, begin / end recording
    /// for video.
    func updateCaptureSounds(isVideoMode: Bool, isRecording: Bool) {
        captureSoundContext = (isVideoMode, isRecording)
        applyCaptureSounds()
    }

    private func applyCaptureSounds() {
        guard usesCustomSounds else {
            captureEventHelper.primarySound = nil
            captureEventHelper.secondarySound = nil
            return
        }
        let context = captureSoundContext
        captureEventHelper.primarySound = if context.isVideoMode {
            context.isRecording ? .endRecording : .beginRecording
        } else {
            .shutter
        }
        // The secondary action flips the camera, which has no system sound.
        captureEventHelper.secondarySound = nil
    }

    // MARK: - Telemetry

    /// Short status tags appended to Studio's telemetry strip.
    func telemetryBadges(from state: PRMCameraState) -> [String] {
        var badges: [String] = []
        let priority = camera.exposurePriorityAxes
        if priority == [.shutter] { badges.append("Tv") }
        if priority == [.iso] { badges.append("Sv") }
        if priority == [.aperture] { badges.append("Av") }
        if camera.device?.apertureRange != nil, state.lensAperture > 0 {
            badges.append(String(format: "f/%.1f", state.lensAperture))
        }
        if state.isPrimaryConstituentLocked { badges.append("LOCK") }
        if state.isContinuousAutoFocusTrackingSubjectAcquired { badges.append("TRACK") }
        if state.isCinematicVideoCaptureEnabled {
            badges.append(state.cinematicSceneStatuses.contains(.notEnoughLight) ? "CINE·DARK" : "CINE")
        }
        if state.lensSmudgeStatus == .smudged { badges.append("SMUDGE") }
        if state.isLowLightVideoNoiseReductionActive { badges.append("NR") }
        if let pressure = Self.pressureBadge(state.systemPressure) { badges.append(pressure) }
        if state.isInterrupted, let reason = state.interruptionReason {
            badges.append("INT:" + Self.name(of: reason))
        }
        if let ratio = state.dynamicAspectRatio { badges.append(ratio.rawValue) }
        return badges
    }

    /// Short name for an interruption reason (also used by Studio's interruption toast).
    static func name(of reason: AVCaptureSession.InterruptionReason) -> String {
        if #available(iOS 26.0, *), reason == .sensitiveContentMitigationActivated {
            return "sensitive-content"
        }
        return switch reason {
        case .videoDeviceNotAvailableInBackground: "background"
        case .audioDeviceInUseByAnotherClient: "audio-busy"
        case .videoDeviceInUseByAnotherClient: "camera-busy"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "multi-app"
        case .videoDeviceNotAvailableDueToSystemPressure: "pressure"
        default: "\(reason.rawValue)"
        }
    }

    /// `WARM` at fair, `HOT` from serious up, with the contributing factors.
    private static func pressureBadge(_ pressure: PRMSystemPressure) -> String? {
        let label: String
        switch pressure.level {
        case .nominal: return nil
        case .fair: label = "WARM"
        case .serious, .critical, .shutdown: label = "HOT"
        }
        let factors: [(PRMSystemPressure.Factors, String)] = [
            (.systemTemperature, "sys"),
            (.peakPower, "power"),
            (.depthModuleTemperature, "depth"),
            (.cameraTemperature, "cam"),
            (.batteryStress, "batt"),
        ]
        let names = factors.filter { pressure.factors.contains($0.0) }.map(\.1)
        return names.isEmpty ? label : "\(label)(\(names.joined(separator: ",")))"
    }

    /// Mirrors device truth back into the controls (modes can change under the user).
    func sync(from state: PRMCameraState, isRecording: Bool) {
        if let device = camera.device, device != lastCheckedDevice {
            applyAvailability(for: device)
        }
        applyStateAvailability(state, isRecording: isRecording)
        isTrackingEnabled = state.isContinuousAutoFocusTrackingEnabled
        isCinematicVideoEnabled = state.isCinematicVideoCaptureEnabled
        trackingSwitch?.isOn = state.isContinuousAutoFocusTrackingEnabled
        if !pendingControls.contains("cinematic") {
            cinematicSwitch?.isOn = state.isCinematicVideoCaptureEnabled
            cinematicRow?.valueText = state.isCinematicVideoCaptureEnabled ? cinematicSummary() : "off"
        }
        if !pendingControls.contains("priority") {
            syncPriority()
        }
        signalsRow?.valueText = signalsValueText(active: state.activeExposureSignals)
        if let slider = trackingBiasSlider, !slider.isTracking {
            slider.value = state.continuousAutoFocusTrackingBias
            trackingBiasRow?.valueText = String(format: "%+.1f", state.continuousAutoFocusTrackingBias)
        }
        if smudgeSwitch?.isOn == true {
            smudgeRow?.valueText = "30 s · \(Self.describe(state.lensSmudgeStatus))"
        }
        noiseReductionRow?.valueText = noiseReductionLabel + (state.isLowLightVideoNoiseReductionActive ? " · active" : "")
        if let row = simulatedApertureRow, let device = camera.device {
            // The depth of field only changes while Cinematic Video runs.
            let unsupported = device.simulatedApertureRange == nil
                ? CameraCapability.cinematicVideo.unavailableMessage(for: "Cinematic depth of field")
                : nil
            row.setDisabled(message: unsupported ?? (state.isCinematicVideoCaptureEnabled ? nil : "Turn on Cinematic Video to change its depth of field"))
        }
        if state.isCinematicVideoCaptureEnabled {
            if let slider = simulatedApertureSlider, !slider.isTracking, state.cinematicSimulatedAperture > 0 {
                slider.value = state.cinematicSimulatedAperture
                simulatedApertureRow?.valueText = String(format: "f/%.1f", state.cinematicSimulatedAperture)
            }
            cinematicMetadataRow?.valueText = cinematicMetadataLabel + (state.isCinematicVideoMetadataCaptureEnabled ? " → on" : " → off")
        } else {
            cinematicMetadataRow?.valueText = cinematicMetadataLabel
        }
        syncAspectRatio(from: state)
        if !state.isContinuousAutoFocusTrackingEnabled, !state.isCinematicVideoCaptureEnabled {
            trackingOverlay.isHidden = true
            if !isDetectingObjects { clearDetections() }
        }
    }

    // MARK: - Giving way

    /// Turns Cinematic Video off for a setting that can't run with it (Studio's conflict
    /// rule), moving the switch without its action. Returns once the camera it moved away
    /// from is back.
    func turnOffCinematicVideo() async {
        cinematicSwitch?.isOn = false
        cinematicRow?.valueText = "off"
        let cameraBefore = camera.device?.uniqueID
        do {
            try await camera.setCinematicVideoEnabled(false)
        } catch {
            toast("Cinematic Video: \(error.localizedDescription)")
        }
        if camera.device?.uniqueID != cameraBefore {
            await cameraDidChange()
        }
    }

    /// Turns Subject Tracking off for Cinematic Video, which drives focus itself.
    func turnOffSubjectTracking() async {
        trackingSwitch?.isOn = false
        await camera.setContinuousAutoFocusTrackingEnabled(false)
    }

    /// Releases Lens Lock before the move to the wide camera that manual controls make: the
    /// lock picks a lens of the virtual camera being left.
    func releaseLensLock() async {
        lensLockControl?.selectedSegmentIndex = 0
        lensLockRow?.valueText = "auto"
        await camera.lockLens(nil)
    }

    private func syncPriority() {
        guard let priorityControl else { return }
        let index = switch camera.exposurePriorityAxes {
        case [.shutter]: 1
        case [.iso]: 2
        case [.aperture] where priorityControl.numberOfSegments > 3: 3
        default: 0
        }
        guard priorityControl.selectedSegmentIndex != index else { return }
        priorityControl.selectedSegmentIndex = index
        priorityRow?.valueText = Self.priorityNames[index]
        if let slider = priorityValueSlider {
            configurePriorityValueSlider(slider, forSegment: index)
        }
    }

    private func syncAspectRatio(from state: PRMCameraState) {
        guard let ratio = state.dynamicAspectRatio else { return }
        if let index = aspectRatios.firstIndex(of: ratio), let aspectControl, !pendingControls.contains("aspect") {
            aspectControl.selectedSegmentIndex = index
        }
        var text = ratio.rawValue
        if let dimensions = state.dynamicDimensions, !dimensions.isEmpty {
            text += " · \(dimensions.width)×\(dimensions.height)"
        }
        aspectRow?.valueText = text
    }

    private func cinematicSummary() -> String {
        guard let fps = camera.device?.cinematicFrameRateRange else { return "on · VIDEO" }
        return "on · VIDEO ≤\(Int(fps.upperBound)) fps"
    }

    // MARK: - Drawer sections

    func makeSections(device: PRMCameraDevice) -> [(title: String, rows: [PRMSettingsRow])] {
        availabilityChecks.removeAll()
        stateChecks.removeAll()
        lastCheckedDevice = device
        return [
            ("Exposure+ (iOS 27)", [
                makePriorityRow(device: device),
                makeApertureRow(device: device),
                makeAperturePaceRow(device: device),
                makeSignalsRow(device: device),
                makeLensLockRow(device: device),
            ]),
            ("Focus+", [
                makeRectFocusRow(device: device),
                makeDetectionRow(),
                makeTrackingRow(device: device),
                makeTrackingBiasRow(device: device),
            ]),
            ("Session health", [
                makeSmudgeRow(device: device),
                makeNoiseReductionRow(device: device),
            ]),
            ("Cinematic Video (iOS 26)", [
                makeCinematicRow(device: device),
                makeCinematicFocusRow(device: device),
                makeSimulatedApertureRow(device: device),
                makeCinematicMetadataRow(device: device),
            ]),
            ("Framing (iOS 26)", [
                makeAspectRatioRow(device: device),
                makeSmartFramingRow(device: device),
            ]),
            ("Controls", [
                makeAirPodsSoundRow(),
            ]),
        ]
    }

    // MARK: Exposure+

    private static let priorityNames = ["off", "shutter", "iso", "aperture"]

    private func makePriorityRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let hasAperture = device.apertureRange != nil
        let segmented = UISegmentedControl(items: hasAperture ? ["Off", "Tv", "Sv", "Av"] : ["Off", "Tv", "Sv"])
        segmented.selectedSegmentIndex = 0
        segmented.accessibilityLabel = "Priority mode"
        // The locked axis's value: shutter in Tv, ISO in Sv (Av uses the Aperture row).
        let slider = UISlider()
        slider.isEnabled = false
        slider.accessibilityLabel = "Priority value"
        let stack = UIStackView(arrangedSubviews: [segmented, slider])
        stack.axis = .vertical
        stack.spacing = 8
        let row = makeRow(symbol: "dial.medium", title: "Priority", value: "off", content: stack)
        segmented.addAction(UIAction { [weak self, weak row, weak slider] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            let index = segmented.selectedSegmentIndex
            row?.valueText = Self.priorityNames[index]
            if let slider {
                configurePriorityValueSlider(slider, forSegment: index)
            }
            applyPending("priority") { [weak self] in
                guard let self else { return }
                if index > 0 {
                    guard await prepare(.manualExposure("Priority")) else { return }
                }
                switch index {
                case 1: await camera.setExposure(aperture: .auto, shutterSeconds: .current, iso: .auto)
                case 2: await camera.setExposure(aperture: .auto, shutterSeconds: .auto, iso: .current)
                case 3: await camera.setExposure(aperture: .current, shutterSeconds: .auto, iso: .auto)
                default:
                    await camera.setExposureMode(.continuousAutoExposure)
                    await didReturnToAutoExposure()
                }
            }
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self, weak row, weak segmented] action in
            guard let self, let slider = action.sender as? UISlider, let segmented else { return }
            switch segmented.selectedSegmentIndex {
            case 1:
                let seconds = Double(exp2(slider.value))
                row?.valueText = "shutter " + CaptureLabels.shutter(seconds)
                runner.run("priorityValue") { [camera] in await camera.setShutterPriority(seconds: seconds) }
            case 2:
                let iso = slider.value.rounded()
                row?.valueText = "iso \(Int(iso))"
                runner.run("priorityValue", deduplicating: iso) { [camera] in await camera.setISOPriority(iso) }
            default:
                break
            }
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.runner.forget("priorityValue") }, for: .touchDown)
        priorityControl = segmented
        priorityValueSlider = slider
        priorityRow = row
        gate(row, device: device) { _ in
            if #available(iOS 27.0, *) { nil } else { "Priority modes need iOS 27" }
        }
        return row
    }

    /// Points the priority row's slider at the locked axis: log₂ seconds for shutter
    /// (capped at 1/2 s so the preview stays live), ISO for ISO; disabled otherwise.
    private func configurePriorityValueSlider(_ slider: UISlider, forSegment index: Int) {
        guard let device = camera.device, index == 1 || index == 2 else {
            slider.isEnabled = false
            return
        }
        slider.isEnabled = true
        if index == 1 {
            let shortest = device.shutterRange.lowerBound
            let longest = min(device.shutterRange.upperBound, 0.5)
            slider.minimumValue = Float(log2(shortest))
            slider.maximumValue = Float(log2(max(longest, shortest)))
            slider.value = Float(log2(camera.state.exposureDurationSeconds ?? 1.0 / 60))
        } else {
            slider.minimumValue = device.isoRange.lowerBound
            slider.maximumValue = device.isoRange.upperBound
            slider.value = camera.state.iso
        }
    }

    private func makeApertureRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        let range = device.apertureRange ?? 1.8 ... 1.8
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.value = range.lowerBound
        let row = makeRow(symbol: "camera.aperture", title: "Aperture", value: String(format: "f/%.1f", range.lowerBound), content: slider)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let fNumber = Self.snapped(slider.value, to: camera.device?.recommendedApertureStops ?? [])
            row?.valueText = String(format: "f/%.1f", fNumber)
            runner.run("aperture", deduplicating: fNumber) { [weak self] in
                guard let self, await prepare(.manualExposure("Aperture")) else { return }
                await camera.setAperturePriority(fNumber)
            }
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.runner.forget("aperture") }, for: .touchDown)
        apertureSlider = slider
        gate(row, device: device) { [weak self] device in
            guard let range = device.apertureRange else { return CameraCapability.variableAperture.unavailableMessage(for: "Aperture") }
            self?.apertureSlider?.minimumValue = range.lowerBound
            self?.apertureSlider?.maximumValue = range.upperBound
            return nil
        }
        return row
    }

    private func makeAperturePaceRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["System", "Smooth", "Fast"])
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "speedometer", title: "Aperture Pace", value: "system", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            // The ratio of aperture area auto exposure may change per frame; 0 restores the
            // system's own pacing.
            let (ratio, label): (Float, String) = switch segmented.selectedSegmentIndex {
            case 1: (1.02, "smooth")
            case 2: (1.5, "fast")
            default: (0, "system")
            }
            row?.valueText = label
            runner.run("aperturePace") { [camera] in await camera.setAutoApertureRateLimit(ratio) }
        }, for: .valueChanged)
        gate(row, device: device, requires: .variableAperture, feature: "Aperture pacing")
        return row
    }

    private func makeSignalsRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let button = UIButton(configuration: .gray())
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "AE signals"
        let row = makeRow(symbol: "sun.max.trianglebadge.exclamationmark", title: "AE Signals", value: "auto", content: button)
        signalsRow = row
        refreshSignalsMenu(button: button, row: row, supported: device.supportedExposureSignals)
        gate(row, device: device, requires: .exposureSignals, feature: "Exposure signals")
        return row
    }

    /// Rebuilds the signals menu after every change. A menu item's checkmark doesn't repaint
    /// while the menu is open, so each pick closes the menu and the next open shows the new
    /// state.
    private func refreshSignalsMenu(button: UIButton, row: PRMSettingsRow, supported: Set<PRMExposureSignal>) {
        button.configuration?.title = enabledSignals.map { "\($0.count) on" } ?? "Automatic"
        row.valueText = signalsValueText(active: camera.state.activeExposureSignals)
        let automatic = UIAction(title: "Automatic", state: enabledSignals == nil ? .on : .off) { [weak self, weak button, weak row] _ in
            guard let self, let button, let row else { return }
            enabledSignals = nil
            refreshSignalsMenu(button: button, row: row, supported: supported)
            runner.run("signals") { [camera] in await camera.setExposureSignals(nil) }
        }
        let toggles = PRMExposureSignal.allCases.filter(supported.contains).map { signal in
            UIAction(
                title: signal.rawValue,
                state: enabledSignals?.contains(signal) == true ? .on : .off
            ) { [weak self, weak button, weak row] _ in
                guard let self, let button, let row else { return }
                var signals = enabledSignals ?? []
                if signals.contains(signal) { signals.remove(signal) } else { signals.insert(signal) }
                enabledSignals = signals
                refreshSignalsMenu(button: button, row: row, supported: supported)
                runner.run("signals") { [camera] in await camera.setExposureSignals(signals) }
            }
        }
        button.menu = UIMenu(children: [automatic, UIMenu(options: .displayInline, children: toggles)])
    }

    /// The picked policy, then the signals auto exposure is acting on right now.
    private func signalsValueText(active: Set<PRMExposureSignal>) -> String {
        let policy = enabledSignals.map { "\($0.count) on" } ?? "auto"
        guard !active.isEmpty else { return policy }
        return policy + " · " + active.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private func makeLensLockRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let types = device.lenses.compactMap(\.deviceType).reduce(into: [AVCaptureDevice.DeviceType]()) { result, type in
            if !result.contains(type) { result.append(type) }
        }
        let segmented = UISegmentedControl(items: ["Auto"] + types.map(Self.shortName))
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "lock.rectangle.stack", title: "Lens Lock", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            let index = segmented.selectedSegmentIndex
            let type = index > 0 && index <= types.count ? types[index - 1] : nil
            row?.valueText = type.map(Self.shortName) ?? "auto"
            runner.run("lensLock") { [camera] in await camera.lockLens(type) }
        }, for: .valueChanged)
        lensLockControl = segmented
        lensLockRow = row
        gate(row, device: device, requires: .lensLock, feature: "Lens lock")
        gateOnState(row) { _, isRecording in isRecording ? "Stop recording to change the lens lock: it switches cameras." : nil }
        return row
    }

    // MARK: Focus+

    private func makeRectFocusRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let toggle = UISwitch()
        let row = makeRow(symbol: "rectangle.dashed", title: "Rect Focus", value: "off", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            usesRectFocus = toggle.isOn
            row?.valueText = toggle.isOn ? Self.rectFocusDescription(camera.device) : "off"
        }, for: .valueChanged)
        gate(row, device: device) {
            CameraCapability.focusRect.isSupported(by: $0) || CameraCapability.exposureRect.isSupported(by: $0)
                ? nil
                : CameraCapability.focusRect.unavailableMessage(for: "Focus and exposure rects")
        }
        return row
    }

    private static func rectFocusDescription(_ device: PRMCameraDevice?) -> String {
        switch (device?.supportsFocusRectOfInterest ?? false, device?.supportsExposureRectOfInterest ?? false) {
        case (true, false): "2× default, focus only"
        case (false, true): "2× default, exposure only"
        default: "2× default"
        }
    }

    /// Faces, bodies or pets from the shared metadata output, outlined over the preview.
    /// Cinematic Video uses its own fixed set while it's on.
    private func makeDetectionRow() -> PRMSettingsRow {
        let options: [(label: String, types: [AVMetadataObject.ObjectType])] = [
            ("Off", []),
            ("Faces", [.face]),
            ("People", [.face, .humanBody]),
            ("Pets", [.catBody, .dogBody]),
        ]
        let segmented = UISegmentedControl(items: options.map(\.label))
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "face.dashed", title: "Detect", value: "off", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, options.indices.contains(segmented.selectedSegmentIndex) else { return }
            let option = options[segmented.selectedSegmentIndex]
            row?.valueText = option.label.lowercased()
            isDetectingObjects = !option.types.isEmpty
            if !isDetectingObjects, !isCinematicVideoEnabled {
                clearDetections()
            }
            runner.run("detection") { [camera] in await camera.setMetadataObjectTypes(option.types) }
        }, for: .valueChanged)
        return row
    }

    private func makeTrackingRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let toggle = UISwitch()
        let row = makeRow(symbol: "scope", title: "Subject Tracking", value: "off", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            let isOn = toggle.isOn
            row?.valueText = isOn ? "tap to track" : "off"
            runner.run("tracking") { [weak self] in
                guard let self else { return }
                if isOn {
                    _ = await prepare(.subjectTracking)
                }
                await camera.setContinuousAutoFocusTrackingEnabled(isOn)
            }
        }, for: .valueChanged)
        trackingSwitch = toggle
        gate(row, device: device, requires: .subjectTracking, feature: "Subject tracking")
        return row
    }

    private func makeTrackingBiasRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = -1
        slider.maximumValue = 1
        slider.value = 0
        let row = makeRow(symbol: "arrow.left.and.right", title: "Tracking Bias", value: "+0.0", content: slider)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let bias = slider.value
            row?.valueText = String(format: "%+.1f", bias)
            runner.run("trackingBias") { [camera] in await camera.setContinuousAutoFocusTrackingBias(bias) }
        }, for: .valueChanged)
        trackingBiasSlider = slider
        trackingBiasRow = row
        gate(row, device: device, requires: .subjectTracking, feature: "Subject tracking")
        gateOnState(row) { state, _ in
            state.isContinuousAutoFocusTrackingEnabled ? nil : "Turn on Subject Tracking to set its bias"
        }
        return row
    }

    // MARK: Session health

    private func makeSmudgeRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let toggle = UISwitch()
        let row = makeRow(symbol: "drop.triangle", title: "Smudge Detection", value: "off", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            row?.valueText = toggle.isOn ? "30 s · checking" : "off"
            let interval: CMTime? = toggle.isOn ? CMTime(value: 30, timescale: 1) : nil
            runner.run("smudge") { [camera] in await camera.setLensSmudgeDetection(interval: interval) }
        }, for: .valueChanged)
        smudgeSwitch = toggle
        smudgeRow = row
        gate(row, device: device, requires: .smudgeDetection, feature: "Smudge detection")
        return row
    }

    private static func describe(_ status: PRMLensSmudgeStatus) -> String {
        switch status {
        case .disabled: "off"
        case .clean: "clean"
        case .smudged: "smudged"
        case .unknown: "checking"
        }
    }

    private func makeNoiseReductionRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let options: [(mode: PRMLowLightVideoNoiseReduction, label: String)] = [(.automatic, "auto"), (.on, "on"), (.off, "off")]
        let segmented = UISegmentedControl(items: ["Auto", "On", "Off"])
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "moon.stars", title: "Low-light NR", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, options.indices.contains(segmented.selectedSegmentIndex) else { return }
            let option = options[segmented.selectedSegmentIndex]
            noiseReductionLabel = option.label
            row?.valueText = option.label
            runner.run("noiseReduction") { [camera] in await camera.setLowLightVideoNoiseReduction(option.mode) }
        }, for: .valueChanged)
        noiseReductionRow = row
        gate(row, device: device, requires: .lowLightNoiseReduction, feature: "Low-light video noise reduction")
        return row
    }

    // MARK: Cinematic Video

    private func makeCinematicRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let toggle = UISwitch()
        let row = makeRow(symbol: "film", title: "Cinematic Video", value: "off", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            let enabled = toggle.isOn
            row?.valueText = enabled ? "turning on…" : "off"
            applyPending("cinematic") { [weak self, weak toggle] in
                guard let self else { return }
                // From a camera without Cinematic Video formats (a Pro iPhone's Triple camera),
                // Prism switches to one that has them and back when it's turned off.
                if enabled {
                    _ = await prepare(.cinematicVideo)
                }
                let cameraBefore = camera.device?.uniqueID
                do {
                    try await camera.setCinematicVideoEnabled(enabled)
                } catch PRMSessionError.cancelled {
                    // A newer toggle or camera switch took over; it sets the switch.
                } catch {
                    toggle?.isOn = !enabled
                    toast("Cinematic Video: \(error.localizedDescription)")
                }
                if camera.device?.uniqueID != cameraBefore {
                    await cameraDidChange()
                }
                // Cinematic Video that ran on the wide camera a manual control had moved to
                // kept Studio there.
                if !enabled {
                    await didReturnToAutoExposure()
                }
            }
        }, for: .valueChanged)
        cinematicSwitch = toggle
        cinematicRow = row
        gate(row, device: device, requires: .cinematicVideo, feature: "Cinematic Video")
        gateOnState(row) { _, isRecording in isRecording ? "Stop recording to change Cinematic Video." : nil }
        return row
    }

    private func makeCinematicFocusRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let styles: [(style: CinematicTapStyle, label: String, value: String)] = [
            (.strong, "Strong", "track, strong"),
            (.weak, "Weak", "track, weak"),
            (.fixed, "Fixed", "fixed distance"),
        ]
        let segmented = UISegmentedControl(items: styles.map(\.label))
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "camera.metering.spot", title: "Cine Tap", value: styles[0].value, content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, styles.indices.contains(segmented.selectedSegmentIndex) else { return }
            let entry = styles[segmented.selectedSegmentIndex]
            cinematicTapStyle = entry.style
            row?.valueText = entry.value
        }, for: .valueChanged)
        gate(row, device: device, requires: .cinematicVideo, feature: "Cinematic Video")
        return row
    }

    private func makeSimulatedApertureRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        let range = device.simulatedApertureRange ?? 2 ... 16
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.value = range.lowerBound
        let row = makeRow(symbol: "camera.filters", title: "Depth Aperture", value: "—", content: slider)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let fNumber = slider.value
            runner.run("simulatedAperture") { [camera, weak row] in
                // `nil` when it can't be set; the error stream says why.
                guard let applied = await camera.setCinematicSimulatedAperture(fNumber) else { return }
                row?.valueText = String(format: "f/%.1f", applied)
            }
        }, for: .valueChanged)
        simulatedApertureSlider = slider
        simulatedApertureRow = row
        gate(row, device: device) { [weak self] device in
            guard let range = device.simulatedApertureRange else {
                return CameraCapability.cinematicVideo.unavailableMessage(for: "Cinematic depth of field")
            }
            self?.simulatedApertureSlider?.minimumValue = range.lowerBound
            self?.simulatedApertureSlider?.maximumValue = range.upperBound
            return nil
        }
        return row
    }

    private func makeCinematicMetadataRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let policies: [(policy: PRMCinematicMetadataCapture, label: String)] = [
            (.automatic, "auto"),
            (.enabled, "on"),
            (.disabled, "off"),
        ]
        let segmented = UISegmentedControl(items: ["Auto", "On", "Off"])
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "film.stack", title: "Cine Metadata", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, policies.indices.contains(segmented.selectedSegmentIndex) else { return }
            let entry = policies[segmented.selectedSegmentIndex]
            cinematicMetadataLabel = entry.label
            row?.valueText = entry.label
            runner.run("cinematicMetadata") { [camera] in await camera.setCinematicMetadataCapture(entry.policy) }
        }, for: .valueChanged)
        cinematicMetadataRow = row
        gate(row, device: device) { device in
            guard CameraCapability.cinematicVideo.isSupported(by: device) else {
                return CameraCapability.cinematicVideo.unavailableMessage(for: "Cinematic Video")
            }
            if #available(iOS 27.0, *) { return nil }
            return "Cinematic metadata capture needs iOS 27"
        }
        return row
    }

    // MARK: Framing

    /// Segments for the ratios the camera this drawer was built for supports; Studio rebuilds
    /// the drawer when the camera flips, which is the only change that moves them (dynamic
    /// aspect ratio is a front-camera feature).
    private func makeAspectRatioRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let ratios = device.supportedDynamicAspectRatios
        aspectRatios = ratios
        let segmented = UISegmentedControl(items: ratios.isEmpty ? ["—"] : ratios.map(\.rawValue))
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "aspectratio", title: "Sensor Aspect", value: ratios.first?.rawValue ?? "—", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, ratios.indices.contains(segmented.selectedSegmentIndex) else { return }
            let ratio = ratios[segmented.selectedSegmentIndex]
            row?.valueText = ratio.rawValue
            applyPending("aspect") { [weak self] in
                guard let self else { return }
                do {
                    try await camera.setDynamicAspectRatio(ratio)
                } catch {
                    toast("Aspect ratio: \(error.localizedDescription)")
                }
            }
        }, for: .valueChanged)
        aspectControl = segmented
        aspectRow = row
        gate(row, device: device, requires: .dynamicAspectRatio, feature: "Dynamic aspect ratio")
        gateOnState(row) { _, isRecording in isRecording ? "Stop recording to change the sensor aspect ratio." : nil }
        return row
    }

    private func makeSmartFramingRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.accessibilityLabel = "Smart Framing"
        let apply = UIButton(configuration: .gray())
        apply.configuration?.title = "Apply"
        apply.accessibilityLabel = "Apply the suggested framing"
        let stack = UIStackView(arrangedSubviews: [toggle, apply])
        stack.spacing = 12
        let row = makeRow(symbol: "person.crop.rectangle", title: "Smart Framing", value: "off", content: stack)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            let isOn = toggle.isOn
            row?.valueText = isOn ? "monitoring" : "off"
            runner.run("smartFraming") { [camera] in
                let framings = isOn ? await camera.supportedFramings() : nil
                await camera.setSmartFraming(enabledFramings: framings)
            }
        }, for: .valueChanged)
        apply.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            guard let framing = latestFraming else {
                toast("No framing suggestion yet")
                return
            }
            row?.valueText = framing.aspectRatio.rawValue + String(format: " at %.1f×", framing.zoomFactor)
            runner.run("applyFraming") { [weak self] in
                guard let self else { return }
                do {
                    try await camera.applyFraming(framing)
                } catch {
                    toast("Framing: \(error.localizedDescription)")
                }
            }
        }, for: .touchUpInside)
        gate(row, device: device, requires: .smartFraming, feature: "Smart Framing")
        return row
    }

    // MARK: Controls

    private func makeAirPodsSoundRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = usesCustomSounds
        let row = makeRow(symbol: "airpods", title: "AirPods Sounds", value: toggle.isOn ? "custom" : "system", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            // Turns off the system's capture sound for the whole app; the helper then plays
            // the shutter for stills and begin / end recording for video.
            PRMCaptureEventHelper.usesCustomCaptureSounds = toggle.isOn
            usesCustomSounds = toggle.isOn
            applyCaptureSounds()
            row?.valueText = toggle.isOn ? "custom" : "system"
        }, for: .valueChanged)
        gate(row, device: nil) { _ in
            if #available(iOS 26.0, *) { nil } else { "AirPods Camera Control needs iOS 26" }
        }
        return row
    }

    // MARK: - Helpers

    private func makeRow(symbol: String, title: String, value: String, content: UIView) -> PRMSettingsRow {
        if let control = content as? UIControl, control.accessibilityLabel == nil {
            control.accessibilityLabel = title
        }
        let row = PRMSettingsRow(symbolName: symbol, title: title, valueText: value, content: content)
        row.onDisabledTap = { [weak self] message in self?.toast(message) }
        return row
    }

    /// Registers a row's availability check and applies it now (when a device is given).
    private func gate(_ row: PRMSettingsRow, device: PRMCameraDevice?, _ reason: @escaping (PRMCameraDevice) -> String?) {
        availabilityChecks.append((row, reason))
        if let device {
            row.setDisabled(message: reason(device))
        } else if let current = camera.device {
            row.setDisabled(message: reason(current))
        }
    }

    /// Gates a row on one capability, with its shared "<feature> needs …" message.
    private func gate(_ row: PRMSettingsRow, device: PRMCameraDevice, requires capability: CameraCapability, feature: String) {
        gate(row, device: device) { capability.isSupported(by: $0) ? nil : capability.unavailableMessage(for: feature) }
    }

    /// Registers a row's session-dependent check (see ``stateChecks``).
    private func gateOnState(_ row: PRMSettingsRow, _ reason: @escaping (PRMCameraState, Bool) -> String?) {
        stateChecks.append((row, reason))
    }

    /// The device's reason wins (the row can't work on this camera at all), then the state's.
    private func applyStateAvailability(_ state: PRMCameraState, isRecording: Bool) {
        guard let device = camera.device else { return }
        for check in stateChecks {
            let deviceReason = availabilityChecks.first { $0.row === check.row }?.reason(device)
            check.row.setDisabled(message: deviceReason ?? check.reason(state, isRecording))
        }
    }

    private func applyAvailability(for device: PRMCameraDevice) {
        lastCheckedDevice = device
        for check in availabilityChecks {
            check.row.setDisabled(message: check.reason(device))
        }
    }

    /// Outlines every detection and frames the subject in focus: yellow while tracking,
    /// faded for a weak Cinematic focus, orange for a fixed one.
    private func showDetections(_ objects: [PRMDetectedObject]) {
        latestObjects = objects
        guard let previewView else { return }
        let subject = objects.first { $0.kind == .focusTracked }
            ?? objects.first { $0.cinematicFocusMode != nil || $0.isFixedFocus }
        let others = objects.filter { $0 != subject && $0.kind != .focusTracked }

        let path = UIBezierPath()
        for object in others {
            path.append(UIBezierPath(rect: viewRect(for: object.bounds, in: previewView)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detectionLayer.frame = previewView.bounds
        detectionLayer.path = path.cgPath
        CATransaction.commit()

        guard let subject else {
            trackingOverlay.isHidden = true
            return
        }
        trackingOverlay.frame = viewRect(for: subject.bounds, in: previewView)
        trackingOverlay.layer.borderColor = if subject.isFixedFocus {
            UIColor.systemOrange.cgColor
        } else if subject.cinematicFocusMode == .weak {
            UIColor.systemYellow.withAlphaComponent(0.5).cgColor
        } else {
            UIColor.systemYellow.cgColor
        }
        trackingOverlay.isHidden = false
    }

    private func clearDetections() {
        latestObjects = []
        detectionLayer.path = nil
    }

    private func viewRect(for bounds: CGRect, in previewView: PRMPreviewView) -> CGRect {
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ].map(previewView.viewPoint(fromTexturePoint:))
        return CGRect(
            x: min(corners[0].x, corners[1].x),
            y: min(corners[0].y, corners[1].y),
            width: abs(corners[1].x - corners[0].x),
            height: abs(corners[1].y - corners[0].y)
        )
    }

    private static func snapped(_ value: Float, to stops: [Float]) -> Float {
        stops.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    private static func shortName(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: "UW"
        case .builtInWideAngleCamera: "W"
        case .builtInTelephotoCamera: "T"
        default: "?"
        }
    }
}

// MARK: - TrackedSubjectOverlay

/// Box around the subject that iOS 27 tracking (or Cinematic Video) is focusing on.
private final class TrackedSubjectOverlay: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        layer.borderColor = UIColor.systemYellow.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
