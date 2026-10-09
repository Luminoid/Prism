@preconcurrency import AVFoundation
import PrismCore
import PrismUI
import SnapKit
import UIKit

// MARK: - StudioDrawerControls

/// Studio's classic drawer sections: exposure, white balance, focus, the zoom ramp, capture
/// (HDR, low-light boost, stabilization) and the photo format (codec, Max Dimensions,
/// red-eye). ``ModernCaptureControls`` adds the iOS 26 / 27 sections after these.
///
/// ``makeSections(device:)`` builds the rows for the current camera; Studio calls it on boot
/// and after a camera flip. Between rebuilds, ``sync(from:context:)`` mirrors the camera state
/// into the rows on every state tick. Control changes go through a latest-wins runner, so a
/// drag sends its values in order and only the newest pending one lands, and a manual change
/// first waits for Studio's single hop to the wide camera.
@MainActor
final class StudioDrawerControls {
    // MARK: - Types

    /// What Studio is doing that locks some rows.
    struct CaptureContext {
        /// A recording is running: exposure presets, white balance and focus would jump in
        /// the movie.
        var isRecording: Bool
        /// Studio is in Night mode, which drives its own exposure.
        var isNightMode: Bool
        /// Night mode plans ISO and shutter per capture, so the manual rows don't apply.
        var nightFixesExposure: Bool
        /// PHOTO, LIVE or PORTRAIT: Max Dimensions applies.
        var isPhotoMode: Bool
        /// The camera is virtual, so a manual control would switch to the wide camera first
        /// (refused while recording).
        var manualNeedsCameraSwitch: Bool
    }

    /// Runner keys: one per camera setting, so exposure changes from different rows still
    /// land in order.
    private enum Key {
        static let exposure = "exposure"
        static let whiteBalance = "whiteBalance"
        static let focus = "focus"
        static let maxDimensions = "maxDimensions"
        static let hdr = "hdr"
        static let lowLight = "lowLight"
        static let stabilization = "stabilization"
    }

    // MARK: - Properties

    /// The Format section's photo settings, read by every Studio capture.
    private(set) var photoCodec: AVVideoCodecType = .hevc
    private(set) var capMaxDimensions = false
    private(set) var autoRedEyeReductionEnabled = false

    private let camera: PRMCamera
    private let toaster: ToastPresenter
    /// Studio's conflict rule before a setting turns on (``StudioViewController/prepare(for:)``):
    /// it turns off what conflicts and, for manual controls, hops to the single wide camera
    /// (virtual devices reject manual values). `false` refuses the change.
    private let prepare: (StudioSetting) async -> Bool
    /// The hop back to the virtual camera once everything is auto again.
    private let didReturnToAutoExposure: () async -> Void
    /// Studio's 35mm-equivalent focal length for a raw zoom factor (the ramp row's labels).
    private let focalLength: (CGFloat) -> Double
    private let runner = LatestWinsRunner()
    private var rampTask: Task<Void, Never>?

    /// Whether > 12MP capture is reachable from the active camera. Recomputed in
    /// ``makeSections(device:)`` and ``deviceDidChange(_:)``, never per state tick.
    private var supportsHighResPhoto = false
    /// Whether the wide camera at a position has a > 12MP format. Hardware doesn't change, so
    /// each position is scanned once.
    private var wideCameraHighResSupport: [AVCaptureDevice.Position: Bool] = [:]
    /// The shutter slider's stops, in seconds, from the active format's range so the slider
    /// can't land on a value the device would clamp.
    private var shutterStops: [Double] = []
    /// Set while a programmatic update writes into a control, so its `.valueChanged` action
    /// doesn't call the camera back.
    private var isApplyingExternalUpdate = false
    private var hdrChoice = "auto"
    private var lowLightChoice = false
    private var stabilizationChoice: StabilizationOption = .auto
    private weak var stabilizationRow: PRMSettingsRow?

    // Rows and controls that `sync(from:context:)` keeps in step with the camera. Weak: the
    // drawer owns them, and a rebuild replaces them.
    private weak var exposureModeSegmented: UISegmentedControl?
    private weak var evRow: PRMSettingsRow?
    private weak var evSlider: UISlider?
    private weak var isoRow: PRMSettingsRow?
    private weak var isoSlider: UISlider?
    private weak var shutterRow: PRMSettingsRow?
    private weak var shutterSlider: UISlider?
    private weak var customExposureSegmented: UISegmentedControl?
    private weak var wbModeSegmented: UISegmentedControl?
    private weak var wbRow: PRMSettingsRow?
    private weak var wbKelvinSlider: UISlider?
    private weak var focusModeSegmented: UISegmentedControl?
    private weak var focusRow: PRMSettingsRow?
    private weak var lensSlider: UISlider?
    private weak var hdrRow: PRMSettingsRow?
    private weak var lowLightRow: PRMSettingsRow?
    private weak var maxDimensionsRow: PRMSettingsRow?
    private weak var maxDimensionsToggle: UISwitch?

    // MARK: - Init

    init(
        camera: PRMCamera,
        toaster: ToastPresenter,
        prepare: @escaping (StudioSetting) async -> Bool,
        didReturnToAutoExposure: @escaping () async -> Void,
        focalLength: @escaping (CGFloat) -> Double
    ) {
        self.camera = camera
        self.toaster = toaster
        self.prepare = prepare
        self.didReturnToAutoExposure = didReturnToAutoExposure
        self.focalLength = focalLength
    }

    deinit {
        rampTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Cancels queued changes and the zoom-ramp watcher (Studio's disappear).
    func stop() {
        runner.cancelAll()
        rampTask?.cancel()
        rampTask = nil
    }

    /// Re-checks what depends on the camera after a device hop, without rebuilding rows.
    func deviceDidChange(_ device: PRMCameraDevice?) {
        supportsHighResPhoto = device.map(highResPhotoReachable) ?? false
        syncMaxDimensionsRow()
    }

    // MARK: - Drawer sections

    func makeSections(device: PRMCameraDevice) -> [(title: String, rows: [PRMSettingsRow])] {
        supportsHighResPhoto = highResPhotoReachable(from: device)
        let sections: [(title: String, rows: [PRMSettingsRow])] = [
            ("Exposure", [
                makeEVRow(device: device),
                makeExposureModeRow(),
                makeISORow(device: device),
                makeShutterRow(device: device),
                makeCustomExposurePresetRow(device: device),
            ]),
            ("White Balance", [
                makeWhiteBalanceModeRow(),
                makeWhiteBalanceRow(),
            ]),
            ("Focus", [
                makeFocusModeRow(),
                makeFocusRow(),
            ]),
            ("Zoom", [
                makeZoomRampRow(device: device),
            ]),
            ("Capture", [
                makeHDRRow(),
                makeLowLightRow(),
                makeStabilizationRow(),
            ]),
            ("Format", [
                makeCodecRow(),
                makeMaxDimensionsRow(),
                makeRedEyeRow(),
            ]),
        ]
        syncMaxDimensionsRow()
        return sections
    }

    // MARK: - Exposure rows

    private func makeEVRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = device.exposureBiasRange.lowerBound
        slider.maximumValue = device.exposureBiasRange.upperBound
        slider.value = camera.state.exposureBias
        let row = makeRow(symbol: "plusminus", title: "EV", value: String(format: "%+0.1f", camera.state.exposureBias), content: slider)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let slider = action.sender as? UISlider else { return }
            let bias = slider.value
            row?.valueText = String(format: "%+0.1f", bias)
            runner.run(Key.exposure) { [camera] in await camera.setExposureBias(bias) }
        }, for: .valueChanged)
        evRow = row
        evSlider = slider
        return row
    }

    /// Locked / Auto / Cont / Custom. Custom is read-only: `.custom` needs a duration and ISO,
    /// so a tap explains where they come from. The state ticks keep the segment truthful
    /// when a drag promotes the mode to Custom.
    private func makeExposureModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont", "Custom"])
        segmented.selectedSegmentIndex = 1
        let row = makeRow(symbol: "lock.shield", title: "Exposure Mode", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let segmented = action.sender as? UISegmentedControl else { return }
            let modes: [AVCaptureDevice.ExposureMode] = [.locked, .autoExpose, .continuousAutoExposure]
            if modes.indices.contains(segmented.selectedSegmentIndex), let device = camera.device,
               !device.supportedExposureModes.contains(modes[segmented.selectedSegmentIndex]) {
                refuse("\(modes[segmented.selectedSegmentIndex].prm_name) exposure", offered: device.supportedExposureModes.map(\.prm_name), by: device)
                Self.applyExposureModeUI(camera.state.exposureMode, to: segmented, row: row)
                return
            }
            switch segmented.selectedSegmentIndex {
            case 0:
                row?.valueText = "locked"
                runner.run(Key.exposure) { [weak self] in
                    guard let self, await prepare(.manualExposure("Locked exposure")) else { return }
                    await camera.setExposureMode(.locked)
                }
            case 1:
                row?.valueText = "auto"
                setAutoExposure(.autoExpose)
            case 2:
                row?.valueText = "continuous"
                setAutoExposure(.continuousAutoExposure)
            default:
                toaster.show("Drag ISO or Shutter to enter Custom")
                Self.applyExposureModeUI(camera.state.exposureMode, to: segmented, row: row)
            }
        }, for: .valueChanged)
        exposureModeSegmented = segmented
        return row
    }

    private func makeISORow(device: PRMCameraDevice) -> PRMSettingsRow {
        let autoChip = TextChip(title: "AUTO")
        autoChip.accessibilityLabel = "Automatic ISO"
        let slider = UISlider()
        slider.minimumValue = device.isoRange.lowerBound
        slider.maximumValue = device.isoRange.upperBound
        slider.value = camera.state.iso
        slider.accessibilityLabel = "ISO"
        let stack = UIStackView(arrangedSubviews: [autoChip, slider])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        autoChip.snp.makeConstraints { $0.width.equalTo(54) }
        let row = makeRow(symbol: "camera.aperture", title: "ISO", value: "auto", content: stack)
        autoChip.onTap = { [weak self, weak row] in
            row?.valueText = "auto"
            self?.setAutoExposure(.continuousAutoExposure)
        }
        // While exposure is automatic the slider parks (see `sync`), so snap it to the live ISO
        // on touch-down: the drag then continues from the value on screen.
        slider.addAction(UIAction { [weak self] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let state = camera.state
            guard Self.isAutoExposure(state.exposureMode), state.iso > 0 else { return }
            slider.value = state.iso
        }, for: .touchDown)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let slider = action.sender as? UISlider else { return }
            let iso = slider.value
            row?.valueText = "\(Int(iso))"
            customExposureSegmented?.selectedSegmentIndex = UISegmentedControl.noSegment
            // Snapshot the auto-exposure baseline before the hop to the wide camera: its auto
            // exposure meters a narrower view, so reciprocity against its own baseline would
            // land on a different brightness than the one on screen.
            let baseline = currentAutoExposureBaseline()
            runner.run(Key.exposure) { [weak self] in
                guard let self, await prepare(.manualExposure("ISO")) else { return }
                await camera.setISO(iso, baseline: baseline)
            }
        }, for: .valueChanged)
        isoRow = row
        isoSlider = slider
        return row
    }

    private func makeShutterRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0.5
        slider.accessibilityLabel = "Shutter speed"
        shutterStops = Self.shutterStops(in: device.shutterRange)
        let row = makeRow(symbol: "stopwatch", title: "Shutter", value: "auto", content: slider)
        // Same touch-down snap as the ISO slider.
        slider.addAction(UIAction { [weak self] action in
            guard let self, let slider = action.sender as? UISlider, !shutterStops.isEmpty else { return }
            runner.forget(Key.exposure)
            let state = camera.state
            guard Self.isAutoExposure(state.exposureMode), let seconds = state.exposureDurationSeconds, seconds > 0 else { return }
            slider.value = sliderPosition(forShutter: seconds)
        }, for: .touchDown)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let slider = action.sender as? UISlider, !shutterStops.isEmpty else { return }
            let index = Int((Double(slider.value) * Double(shutterStops.count - 1)).rounded())
            let seconds = shutterStops[max(0, min(shutterStops.count - 1, index))]
            row?.valueText = CaptureLabels.shutter(seconds)
            customExposureSegmented?.selectedSegmentIndex = UISegmentedControl.noSegment
            let baseline = currentAutoExposureBaseline()
            runner.run(Key.exposure, deduplicating: seconds) { [weak self] in
                guard let self, await prepare(.manualExposure("Shutter")) else { return }
                await camera.setShutterSpeed(seconds: seconds, baseline: baseline)
            }
        }, for: .valueChanged)
        shutterRow = row
        shutterSlider = slider
        return row
    }

    private func makeCustomExposurePresetRow(device: PRMCameraDevice) -> PRMSettingsRow {
        let presets: [(label: String, duration: CMTime, iso: Float)] = [
            ("Day", CMTime(value: 1, timescale: 500), max(50, device.isoRange.lowerBound)),
            ("Indoor", CMTime(value: 1, timescale: 60), min(400, device.isoRange.upperBound)),
            ("Night", CMTime(value: 1, timescale: 30), min(1600, device.isoRange.upperBound)),
        ]
        let segmented = UISegmentedControl(items: presets.map(\.label))
        segmented.selectedSegmentIndex = UISegmentedControl.noSegment
        let row = makeRow(symbol: "wand.and.stars", title: "Custom Exposure", value: "—", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let segmented = action.sender as? UISegmentedControl,
                  presets.indices.contains(segmented.selectedSegmentIndex)
            else { return }
            let preset = presets[segmented.selectedSegmentIndex]
            let seconds = CMTimeGetSeconds(preset.duration)
            row?.valueText = "\(CaptureLabels.shutter(seconds)) · ISO \(Int(preset.iso))"
            // Show the preset in the ISO and Shutter sliders so a drag continues from it; the
            // mode segment follows on the next state tick.
            syncManualExposureControls(durationSeconds: seconds, iso: preset.iso)
            runner.run(Key.exposure) { [weak self] in
                guard let self, await prepare(.manualExposure("Custom exposure")) else { return }
                await camera.setCustomExposure(duration: preset.duration, iso: preset.iso)
            }
        }, for: .valueChanged)
        customExposureSegmented = segmented
        return row
    }

    private func setAutoExposure(_ mode: AVCaptureDevice.ExposureMode) {
        runner.run(Key.exposure) { [weak self] in
            guard let self else { return }
            await camera.setExposureMode(mode)
            await didReturnToAutoExposure()
        }
    }

    /// The reciprocity reference for the first manual change: the on-screen auto exposure,
    /// read before any device hop. `nil` once in manual, where `PRMCamera` keeps its own.
    private func currentAutoExposureBaseline() -> (iso: Float, durationSeconds: Double)? {
        let state = camera.state
        guard Self.isAutoExposure(state.exposureMode), state.iso > 0,
              let duration = state.exposureDurationSeconds, duration > 0
        else { return nil }
        return (iso: state.iso, durationSeconds: duration)
    }

    // MARK: - White balance rows

    private func makeWhiteBalanceModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont"])
        segmented.selectedSegmentIndex = 1
        let row = makeRow(symbol: "circle.dashed", title: "WB Mode", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let segmented = action.sender as? UISegmentedControl else { return }
            let (mode, label): (AVCaptureDevice.WhiteBalanceMode, String) = switch segmented.selectedSegmentIndex {
            case 0: (.locked, "locked")
            case 1: (.autoWhiteBalance, "auto")
            default: (.continuousAutoWhiteBalance, "continuous")
            }
            // iPhone cameras have no one-shot auto white balance.
            if let device = camera.device, !device.supportedWhiteBalanceModes.contains(mode) {
                refuse("\(mode.prm_name) white balance", offered: device.supportedWhiteBalanceModes.map(\.prm_name), by: device)
                segmented.selectedSegmentIndex = Self.whiteBalanceSegment(for: camera.state.whiteBalanceMode)
                return
            }
            row?.valueText = label
            runner.run(Key.whiteBalance) { [weak self] in
                guard let self else { return }
                if mode == .locked {
                    guard await prepare(.whiteBalanceLock("Locked white balance")) else { return }
                    await camera.setWhiteBalanceMode(mode)
                } else {
                    await camera.setWhiteBalanceMode(mode)
                    await didReturnToAutoExposure()
                }
            }
        }, for: .valueChanged)
        wbModeSegmented = segmented
        return row
    }

    /// Kelvin slider plus presets. On iOS 26 the presets lock to Apple's calibrated
    /// temperature and tint; older systems use the nominal Kelvin values.
    private func makeWhiteBalanceRow() -> PRMSettingsRow {
        let kelvinSlider = UISlider()
        kelvinSlider.minimumValue = 2500
        kelvinSlider.maximumValue = 8000
        kelvinSlider.value = camera.state.whiteBalanceTemperature
        kelvinSlider.accessibilityLabel = "White balance temperature"
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 6
        chips.distribution = .fillEqually
        let presets: [(label: String, name: String, preset: AVCaptureDevice.PRMWhiteBalancePreset)] = [
            ("Tung", "Tungsten", .tungsten),
            ("Fluor", "Fluorescent", .fluorescent),
            ("Day", "Daylight", .daylight),
            ("Cloud", "Cloudy", .cloudy),
            ("Shade", "Shade", .shade),
        ]
        let stack = UIStackView(arrangedSubviews: [kelvinSlider, chips])
        stack.axis = .vertical
        stack.spacing = 8
        let row = makeRow(symbol: "thermometer.sun", title: "WB", value: "\(Int(camera.state.whiteBalanceTemperature))K", content: stack)
        for entry in presets {
            let chip = TextChip(title: entry.label)
            chip.accessibilityLabel = "\(entry.name) white balance"
            chip.onTap = { [weak self, weak row, weak kelvinSlider] in
                guard let self else { return }
                let values = entry.preset.temperatureAndTint
                row?.valueText = "\(Int(values.temperature))K"
                isApplyingExternalUpdate = true
                kelvinSlider?.value = values.temperature
                isApplyingExternalUpdate = false
                // Locking moves the mode to Locked; the WB Mode segment follows on the next tick.
                runner.run(Key.whiteBalance) { [weak self] in
                    guard let self, await prepare(.whiteBalanceLock("\(entry.name) white balance")) else { return }
                    await camera.lockWhiteBalance(preset: entry.preset)
                }
            }
            chips.addArrangedSubview(chip)
        }
        kelvinSlider.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let slider = action.sender as? UISlider else { return }
            let kelvin = slider.value
            row?.valueText = "\(Int(kelvin))K"
            let values = AVCaptureDevice.PRMTemperatureAndTint(temperature: kelvin, tint: 0)
            runner.run(Key.whiteBalance) { [weak self] in
                guard let self, await prepare(.whiteBalanceLock("White balance")) else { return }
                await camera.lockWhiteBalance(values)
            }
        }, for: .valueChanged)
        wbRow = row
        wbKelvinSlider = kelvinSlider
        return row
    }

    // MARK: - Focus rows

    private func makeFocusModeRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Locked", "Auto", "Cont"])
        segmented.selectedSegmentIndex = 2
        let row = makeRow(symbol: "scope", title: "Focus Mode", value: "continuous", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let segmented = action.sender as? UISegmentedControl else { return }
            let (mode, label): (AVCaptureDevice.FocusMode, String) = switch segmented.selectedSegmentIndex {
            case 0: (.locked, "locked")
            case 1: (.autoFocus, "auto")
            default: (.continuousAutoFocus, "continuous")
            }
            if let device = camera.device, !device.supportedFocusModes.contains(mode) {
                refuse("\(mode.prm_name) focus", offered: device.supportedFocusModes.map(\.prm_name), by: device)
                segmented.selectedSegmentIndex = Self.focusSegment(for: camera.state.focusMode)
                return
            }
            row?.valueText = label
            // Cinematic Video owns focus (AVFoundation raises on a focus-mode change), so it
            // gives way first; the facade would refuse otherwise.
            runner.run(Key.focus) { [weak self] in
                guard let self, await prepare(.focusMode) else { return }
                await camera.setFocusMode(mode)
                // A locked focus kept Studio on the wide camera.
                if mode != .locked {
                    await didReturnToAutoExposure()
                }
            }
        }, for: .valueChanged)
        focusModeSegmented = segmented
        return row
    }

    private func makeFocusRow() -> PRMSettingsRow {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = camera.state.lensPosition
        slider.accessibilityLabel = "Focus distance"
        let hint = UILabel()
        hint.textColor = UIColor.white.withAlphaComponent(0.6)
        hint.font = ExampleFont.scaled(11, style: .caption2)
        hint.adjustsFontForContentSizeCategory = true
        hint.text = "Drag to lock focus distance"
        hint.isAccessibilityElement = false
        let stack = UIStackView(arrangedSubviews: [slider, hint])
        stack.axis = .vertical
        stack.spacing = 6
        let row = makeRow(symbol: "scope", title: "Focus", value: String(format: "%.2f", camera.state.lensPosition), content: stack)
        slider.addAction(UIAction { [weak self, weak row] action in
            guard let self, !isApplyingExternalUpdate, let slider = action.sender as? UISlider else { return }
            let position = slider.value
            row?.valueText = String(format: "%.2f", position)
            // Locking a lens position moves focus to Locked. Virtual devices refuse custom lens
            // positions (only the physical wide camera honors them), so hop first.
            runner.run(Key.focus) { [weak self] in
                guard let self, await prepare(.manualFocus) else { return }
                await camera.setLensPosition(position)
            }
        }, for: .valueChanged)
        focusRow = row
        lensSlider = slider
        return row
    }

    // MARK: - Zoom row

    /// Ramps between the focal lengths at 1× and 2× raw zoom, whichever is further from the
    /// current zoom, so every tap moves visibly.
    private func makeZoomRampRow(device: PRMCameraDevice) -> PRMSettingsRow {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Ramp"
        configuration.baseForegroundColor = .systemYellow
        let button = UIButton(configuration: configuration)
        let idleLabel = "\(CaptureLabels.focalLength(focalLength(1.0))) ↔ \(CaptureLabels.focalLength(focalLength(2.0)))"
        let row = makeRow(symbol: "arrow.up.right.and.arrow.down.left.rectangle", title: "Smooth Ramp", value: idleLabel, content: button)
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
        button.addAction(UIAction { [weak self, weak row] action in
            guard let self, let button = action.sender as? UIButton else { return }
            if let rampTask {
                rampTask.cancel()
                self.rampTask = nil
                runner.run("ramp") { [camera] in await camera.cancelZoomRamp() }
                row?.valueText = idleLabel
                button.configuration?.title = "Ramp"
                return
            }
            let current = camera.state.zoomFactor
            let target = min(max(current < 1.5 ? 2.0 : 1.0, device.minZoomFactor), device.maxZoomFactor)
            guard abs(target - current) > 0.05 else {
                toaster.show("Already at \(CaptureLabels.focalLength(focalLength(target)))")
                return
            }
            row?.valueText = "ramping → \(CaptureLabels.focalLength(focalLength(target)))…"
            button.configuration?.title = "Cancel"
            rampTask = Task { [weak self, weak row, weak button, camera] in
                await camera.rampZoom(to: target, rate: 1.0)
                // Re-read the state at ~30 Hz while AVFoundation ramps, so the telemetry's focal
                // length moves smoothly instead of jumping at the 2 Hz idle refresh.
                while !Task.isCancelled, await Self.isRampingZoom(camera.session) {
                    await camera.refreshState()
                    try? await Task.sleep(for: .milliseconds(33))
                }
                guard !Task.isCancelled else { return }
                // One last read lands the telemetry on the committed zoom factor.
                await camera.refreshState()
                self?.rampTask = nil
                row?.valueText = idleLabel
                button?.configuration?.title = "Ramp"
            }
        }, for: .touchUpInside)
        return row
    }

    @PRMCameraActor
    private static func isRampingZoom(_ session: PRMCameraSession) -> Bool {
        session.videoDevice?.isRampingVideoZoom ?? false
    }

    // MARK: - Capture rows

    private func makeHDRRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["Auto", "On", "Off"])
        segmented.selectedSegmentIndex = 0
        let row = makeRow(symbol: "circle.lefthalf.filled", title: "HDR", value: "auto", content: segmented)
        segmented.addAction(UIAction { [weak self] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            let (enabled, label): (Bool?, String) = switch segmented.selectedSegmentIndex {
            case 1: (true, "on")
            case 2: (false, "off")
            default: (nil, "auto")
            }
            hdrChoice = label
            hdrRow?.valueText = label
            logChoice("HDR", label)
            runner.run(Key.hdr) { [camera] in await camera.setVideoHDR(enabled) }
        }, for: .valueChanged)
        hdrRow = row
        return row
    }

    private func makeLowLightRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = lowLightChoice
        let row = makeRow(symbol: "moon.stars", title: "Low-Light Boost", value: lowLightChoice ? "on" : "off", content: toggle)
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            let isOn = toggle.isOn
            lowLightChoice = isOn
            lowLightRow?.valueText = isOn ? "on" : "off"
            logChoice("Low-Light Boost", isOn ? "on" : "off")
            runner.run(Key.lowLight) { [camera] in await camera.setLowLightBoost(isOn) }
        }, for: .valueChanged)
        lowLightRow = row
        return row
    }

    private func makeStabilizationRow() -> PRMSettingsRow {
        let options = StabilizationOption.available
        let segmented = UISegmentedControl(items: options.map(\.label))
        segmented.selectedSegmentIndex = options.firstIndex(of: .auto) ?? 0
        let row = makeRow(symbol: "hand.raised", title: "Stabilization", value: StabilizationOption.auto.name, content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl, options.indices.contains(segmented.selectedSegmentIndex) else { return }
            let option = options[segmented.selectedSegmentIndex]
            stabilizationChoice = option
            row?.valueText = option.name
            logChoice("Stabilization", option.name)
            runner.run(Key.stabilization) { [camera] in await camera.setStabilization(option.mode) }
        }, for: .valueChanged)
        stabilizationRow = row
        return row
    }

    // MARK: - Format rows

    private func makeCodecRow() -> PRMSettingsRow {
        let segmented = UISegmentedControl(items: ["JPEG", "HEIC"])
        segmented.selectedSegmentIndex = photoCodec == .jpeg ? 0 : 1
        let row = makeRow(symbol: "doc.zipper", title: "Codec", value: photoCodec == .jpeg ? "jpeg" : "heic", content: segmented)
        segmented.addAction(UIAction { [weak self, weak row] action in
            guard let self, let segmented = action.sender as? UISegmentedControl else { return }
            photoCodec = segmented.selectedSegmentIndex == 0 ? .jpeg : .hevc
            row?.valueText = photoCodec == .jpeg ? "jpeg" : "heic"
            logChoice("Codec", photoCodec == .jpeg ? "jpeg" : "heic")
        }, for: .valueChanged)
        return row
    }

    /// Max Dimensions switches the active format to the 48MP one, which only the physical wide
    /// camera has: virtual devices top out at their fusion formats (24MP on iPhone 15 Pro Max),
    /// so turning it on hops to the wide camera first and turning it off hops back once
    /// everything is automatic again. Turning it on turns off what it can't run with (LIVE,
    /// PORTRAIT and BURST, Cinematic Video, manual exposure and white balance); see
    /// ``StudioViewController/prepare(for:)``.
    private func makeMaxDimensionsRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = capMaxDimensions
        let row = makeRow(symbol: "square.dashed", title: "Max Dimensions", value: capMaxDimensions ? "cap" : "default", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            let isOn = toggle.isOn
            capMaxDimensions = isOn
            row?.valueText = isOn ? "cap" : "default"
            ExampleLog.session.notice("Studio Max Dimensions → \(isOn ? "on" : "off", privacy: .public)")
            setHighResolutionFormat(isOn)
        }, for: .valueChanged)
        maxDimensionsRow = row
        maxDimensionsToggle = toggle
        return row
    }

    private func setHighResolutionFormat(_ isOn: Bool) {
        runner.run(Key.maxDimensions) { [weak self] in
            guard let self else { return }
            if isOn, await !prepare(.maxDimensions) {
                showMaxDimensions(false)
                return
            }
            // A refusal (reported on the error stream) leaves the switch where the format is.
            if await !camera.setHighResolutionPhotoFormat(isOn) {
                showMaxDimensions(!isOn)
                return
            }
            if !isOn {
                await didReturnToAutoExposure()
            }
        }
    }

    /// Turns Max Dimensions off for a setting that can't run with it (Studio's conflict rule),
    /// moving the switch without its action. Returns once the regular format is back.
    func turnOffMaxDimensions() async {
        guard capMaxDimensions else { return }
        showMaxDimensions(false)
        ExampleLog.session.notice("Studio Max Dimensions → off (a newer setting needs it off)")
        await camera.setHighResolutionPhotoFormat(false)
    }

    private func showMaxDimensions(_ isOn: Bool) {
        capMaxDimensions = isOn
        maxDimensionsToggle?.isOn = isOn
        maxDimensionsRow?.valueText = isOn ? "cap" : "default"
    }

    private func makeRedEyeRow() -> PRMSettingsRow {
        let toggle = UISwitch()
        toggle.isOn = autoRedEyeReductionEnabled
        let row = makeRow(symbol: "eye.trianglebadge.exclamationmark", title: "Auto Red-Eye", value: autoRedEyeReductionEnabled ? "on" : "off", content: toggle)
        toggle.addAction(UIAction { [weak self, weak row] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            autoRedEyeReductionEnabled = toggle.isOn
            row?.valueText = toggle.isOn ? "on" : "off"
            logChoice("Auto Red-Eye", toggle.isOn ? "on" : "off")
        }, for: .valueChanged)
        return row
    }

    /// Whether > 12MP capture is reachable: the active camera has it, or the wide camera at
    /// the same position does (the toggle hops there). Virtual devices cap at 12MP.
    private func highResPhotoReachable(from device: PRMCameraDevice) -> Bool {
        let twelveMegapixels = Int64(4032) * Int64(3024)
        if let dims = device.maxSupportedPhotoDimensions, Int64(dims.width) * Int64(dims.height) > twelveMegapixels {
            return true
        }
        if let cached = wideCameraHighResSupport[device.position] {
            return cached
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: device.position)
        let supported = discovery.devices.contains { candidate in
            candidate.formats.contains { format in
                format.supportedMaxPhotoDimensions.contains { $0.width >= $0.height && Int64($0.width) * Int64($0.height) > twelveMegapixels }
            }
        }
        wideCameraHighResSupport[device.position] = supported
        return supported
    }

    /// Disables Max Dimensions where > 12MP isn't reachable (front cameras). A switch that was
    /// on turns off and the format goes back, so the session's high-resolution intent doesn't
    /// follow the camera.
    private func syncMaxDimensionsRow() {
        guard let row = maxDimensionsRow else { return }
        row.setDisabled(message: maxDimensionsDisabledMessage(isPhotoMode: true))
        guard !supportsHighResPhoto, capMaxDimensions else { return }
        showMaxDimensions(false)
        var change = SettingChange(camera.device?.localizedName ?? "This camera")
        change.turnedOff("Max Dimensions", because: "it caps at 12 MP")
        toaster.gaveWay(change)
        setHighResolutionFormat(false)
    }

    /// Why Max Dimensions can't be changed now: a camera without > 12MP, or a mode that
    /// doesn't take photos from the format (the switch keeps its setting for PHOTO).
    private func maxDimensionsDisabledMessage(isPhotoMode: Bool) -> String? {
        if !supportsHighResPhoto {
            return "This camera caps at 12MP. Use the back camera for higher resolution."
        }
        if isPhotoMode {
            return nil
        }
        return capMaxDimensions
            ? "Max Dimensions is for photos. It stays on for when you go back to PHOTO."
            : "Max Dimensions is for photos. Switch to PHOTO to use it."
    }

    /// One line for a drawer choice the camera doesn't log itself, so a pasted log shows it
    /// (a JPEG photo right after the Codec row went to JPEG, for one).
    private func logChoice(_ title: String, _ value: String) {
        ExampleLog.session.notice("Studio \(title, privacy: .public) → \(value, privacy: .public)")
    }

    // MARK: - Sync

    /// Mirrors the camera state into the rows and applies the rules that disable some.
    ///
    /// Sliders follow the state only in their manual mode (ISO / Shutter under `.custom`
    /// exposure, Kelvin under locked white balance, the lens under locked focus): in auto
    /// modes AVFoundation moves those values every frame, and syncing them would drag the
    /// slider away from the user and make a first drag snap back before the device commits.
    /// The row values always show the live reading, marked "(auto)" in auto modes.
    func sync(from state: PRMCameraState, context: CaptureContext) {
        // What the connection actually runs can differ from the choice (the format may not
        // support it); show both.
        stabilizationRow?.valueText = "\(stabilizationChoice.name) → \(StabilizationOption.activeName(of: state.activeStabilizationMode))"
        if let exposureModeSegmented {
            Self.applyExposureModeUI(state.exposureMode, to: exposureModeSegmented, row: nil)
        }
        if let evSlider, !evSlider.isTracking {
            evSlider.value = state.exposureBias
        }
        evRow?.valueText = String(format: "%+0.1f", state.exposureBias)

        let isCustom = state.exposureMode == .custom
        if isCustom, let isoSlider, !isoSlider.isTracking {
            isoSlider.value = state.iso
        }
        isoRow?.valueText = isCustom ? "\(Int(state.iso))" : "\(Int(state.iso)) (auto)"
        if isCustom, let shutterSlider, !shutterSlider.isTracking, let seconds = state.exposureDurationSeconds {
            shutterSlider.value = sliderPosition(forShutter: seconds)
        }
        shutterRow?.valueText = state.exposureDurationSeconds.map { isCustom ? CaptureLabels.shutter($0) : "\(CaptureLabels.shutter($0)) (auto)" } ?? "auto"

        wbModeSegmented?.selectedSegmentIndex = Self.whiteBalanceSegment(for: state.whiteBalanceMode)
        if state.whiteBalanceMode == .locked, let wbKelvinSlider, !wbKelvinSlider.isTracking {
            wbKelvinSlider.value = state.whiteBalanceTemperature
        }
        let kelvin = "\(Int(state.whiteBalanceTemperature))K"
        wbRow?.valueText = state.whiteBalanceMode == .locked ? kelvin : "\(kelvin) (auto)"

        focusModeSegmented?.selectedSegmentIndex = Self.focusSegment(for: state.focusMode)
        if state.focusMode == .locked, let lensSlider, !lensSlider.isTracking {
            lensSlider.value = state.lensPosition
        }
        let lens = String(format: "%.2f", state.lensPosition)
        focusRow?.valueText = state.focusMode == .locked ? lens : "\(lens) (auto)"

        // What actually landed: an HDR or boost request the format can't honor reads "off".
        hdrRow?.valueText = "\(hdrChoice) → \(state.isVideoHDREnabled ? "on" : "off")"
        lowLightRow?.valueText = lowLightChoice ? (state.isLowLightBoostActive ? "on · boosting" : "on") : "off"

        applyDisabledStates(from: state, context: context)
    }

    /// One rule per control for when AVFoundation would ignore (or fight) a change, surfaced
    /// as a disabled row that explains itself on tap.
    private func applyDisabledStates(from state: PRMCameraState, context: CaptureContext) {
        // EV bias trims the auto-exposure target, so custom exposure ignores it.
        evRow?.setDisabled(message: state.exposureMode == .custom ? "EV bias is ignored under custom exposure" : nil)

        // Changing exposure mid-recording flickers at the next sample boundary, and Night
        // drives its own exposure.
        let presetsLocked = context.isRecording || context.isNightMode
        customExposureSegmented?.isEnabled = !presetsLocked
        customExposureSegmented?.alpha = presetsLocked ? 0.45 : 1

        // A manual change on a virtual camera switches to the wide camera, which a recording
        // can't survive.
        let switchWhileRecording = context.isRecording && context.manualNeedsCameraSwitch
        isoRow?.setDisabled(message: context.nightFixesExposure
            ? "Night mode sets ISO for each capture"
            : switchWhileRecording ? "Stop recording to change ISO: manual exposure needs the wide camera." : nil)
        shutterRow?.setDisabled(message: context.nightFixesExposure
            ? "Night mode sets the shutter for each capture"
            : switchWhileRecording ? "Stop recording to change the shutter: manual exposure needs the wide camera." : nil)
        maxDimensionsRow?.setDisabled(message: maxDimensionsDisabledMessage(isPhotoMode: context.isPhotoMode))
        hdrRow?.setDisabled(message: camera.device?.supportsVideoHDR == false ? "This camera format has no video HDR" : nil)
        lowLightRow?.setDisabled(message: camera.device?.supportsLowLightBoost == false ? "This camera has no low-light boost" : nil)

        let recordingMessage = context.isRecording ? "Setting locked while recording" : nil
        let customWhiteBalanceMessage = camera.device?.supportsCustomWhiteBalance == false
            ? "This camera can't lock white balance to a temperature"
            : nil
        wbRow?.setDisabled(message: recordingMessage ?? customWhiteBalanceMessage)
        // Virtual devices report locked focus as supported but throw on a custom lens position.
        let lensPositionMessage = camera.device?.supportsCustomLensPosition == false
            ? "Manual focus needs the wide camera. Drag ISO or Shutter to switch."
            : nil
        focusRow?.setDisabled(message: recordingMessage ?? lensPositionMessage)
    }

    /// Writes a duration and ISO into the ISO and Shutter sliders without calling the camera.
    private func syncManualExposureControls(durationSeconds: Double, iso: Float) {
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }
        isoSlider?.value = iso
        isoRow?.valueText = "\(Int(iso))"
        if let shutterSlider, !shutterStops.isEmpty {
            shutterSlider.value = sliderPosition(forShutter: durationSeconds)
            shutterRow?.valueText = CaptureLabels.shutter(durationSeconds)
        }
    }

    // MARK: - Helpers

    private func makeRow(symbol: String, title: String, value: String, content: UIView) -> PRMSettingsRow {
        if let control = content as? UIControl, control.accessibilityLabel == nil {
            control.accessibilityLabel = title
        }
        let row = PRMSettingsRow(symbolName: symbol, title: title, valueText: value, content: content)
        row.onDisabledTap = { [weak self] message in self?.toaster.refused(title, because: message) }
        return row
    }

    private func sliderPosition(forShutter seconds: Double) -> Float {
        let index = Self.nearestStopIndex(to: seconds, in: shutterStops)
        return Float(Double(index) / Double(max(shutterStops.count - 1, 1)))
    }

    private static func isAutoExposure(_ mode: AVCaptureDevice.ExposureMode) -> Bool {
        mode == .continuousAutoExposure || mode == .autoExpose
    }

    /// Apple Camera's stops from 1/8000 s to 2 s, limited to the device's range.
    private static func shutterStops(in range: ClosedRange<Double>) -> [Double] {
        let candidates: [Double] = [
            1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
            1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1.0, 2.0,
        ]
        return candidates.filter { range.contains($0) }
    }

    /// The stop closest to `seconds` in log space, where 1/60 is one stop from 1/30.
    private static func nearestStopIndex(to seconds: Double, in stops: [Double]) -> Int {
        guard seconds > 0, !stops.isEmpty else { return 0 }
        let target = log(seconds)
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (index, stop) in stops.enumerated() where stop > 0 {
            let distance = abs(log(stop) - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Toasts and logs that the camera has no `mode` and what it offers instead; the caller puts
    /// the segment back.
    private func refuse(_ mode: String, offered: [String], by device: PRMCameraDevice) {
        let message = "\(device.localizedName) has no \(mode). It offers \(ListFormatter.localizedString(byJoining: offered))."
        toaster.refused(mode, because: message)
    }

    private static func whiteBalanceSegment(for mode: AVCaptureDevice.WhiteBalanceMode) -> Int {
        switch mode {
        case .locked: 0
        case .continuousAutoWhiteBalance: 2
        default: 1
        }
    }

    private static func focusSegment(for mode: AVCaptureDevice.FocusMode) -> Int {
        switch mode {
        case .locked: 0
        case .autoFocus: 1
        default: 2
        }
    }

    private static func applyExposureModeUI(_ mode: AVCaptureDevice.ExposureMode, to segmented: UISegmentedControl, row: PRMSettingsRow?) {
        let (index, label) = switch mode {
        case .locked: (0, "locked")
        case .continuousAutoExposure: (2, "continuous")
        case .custom: (3, "custom")
        default: (1, "auto")
        }
        segmented.selectedSegmentIndex = index
        row?.valueText = label
    }
}
