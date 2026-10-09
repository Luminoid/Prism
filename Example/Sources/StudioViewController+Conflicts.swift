@preconcurrency import AVFoundation
import PrismCore

// MARK: - StudioSetting

/// A setting a Studio control is about to turn on, for ``StudioViewController/prepare(for:)``.
enum StudioSetting {
    case maxDimensions
    /// ISO, Shutter, an exposure preset, Locked exposure, a priority mode or the aperture;
    /// the associated name is the control's.
    case manualExposure(String)
    /// The Kelvin slider, a white balance preset or Locked white balance.
    case whiteBalanceLock(String)
    /// The lens-position slider.
    case manualFocus
    /// The Focus Mode segment.
    case focusMode
    case cinematicVideo
    case subjectTracking

    /// The name the toast and log line use.
    var name: String {
        switch self {
        case .maxDimensions: "Max Dimensions"
        case let .manualExposure(control), let .whiteBalanceLock(control): control
        case .manualFocus: "Manual focus"
        case .focusMode: "Focus Mode"
        case .cinematicVideo: "Cinematic Video"
        case .subjectTracking: "Subject Tracking"
        }
    }

    /// Runs on the physical wide camera: virtual cameras reject manual values, and the 48MP
    /// format is the wide camera's.
    var needsWideCamera: Bool {
        switch self {
        case .maxDimensions, .manualExposure, .whiteBalanceLock, .manualFocus: true
        case .focusMode, .cinematicVideo, .subjectTracking: false
        }
    }
}

// MARK: - Conflicts

/// Studio's rule for settings that can't be on together: the newest wins. Turning one on
/// turns off what it conflicts with first, moves those controls to match, and says what
/// changed in one toast and one `Conflict:` log line. Studio refuses only what a recording
/// in progress would have to stop for (the rows the camera can't run are disabled up front).
///
/// | Turned on | Turns off |
/// |---|---|
/// | Max Dimensions | LIVE, PORTRAIT, BURST (to PHOTO); Cinematic Video; manual exposure and locked white balance |
/// | Manual exposure or white balance | Max Dimensions; Cinematic Video; LIVE (to PHOTO); PORTRAIT (to PHOTO) for exposure, or for white balance on a virtual camera |
/// | Manual focus | Cinematic Video; PORTRAIT (to PHOTO) on a virtual camera |
/// | Focus Mode, Subject Tracking | Cinematic Video |
/// | Cinematic Video | Max Dimensions; Subject Tracking; manual exposure and white balance; PHOTO, LIVE, PORTRAIT, NIGHT, SLO-MO (to VIDEO) |
/// | LIVE, PORTRAIT, BURST | Max Dimensions |
/// | PHOTO, LIVE, PORTRAIT, NIGHT, SLO-MO | Cinematic Video |
/// | LIVE | manual exposure and locked white balance |
/// | PORTRAIT | manual exposure |
///
/// A move to the wide camera for a manual control also releases Lens Lock.
extension StudioViewController {
    /// Makes room for `setting` and, for a manual control, moves to the wide camera. Returns
    /// `false` when the change is refused (the reason was toasted): a recording is running
    /// and the change would need a camera switch.
    func prepare(for setting: StudioSetting) async -> Bool {
        if setting.needsWideCamera, recordingStartedAt != nil, needsWideCameraForManual {
            toaster.refused(setting.name, because: "Stop recording to change \(setting.name): it needs the wide camera.")
            return false
        }
        var change = SettingChange(setting.name)
        await makeRoom(for: setting, recording: &change)
        toaster.gaveWay(change)
        if setting.needsWideCamera {
            await prepareForManualExposure(for: setting.name)
        }
        return true
    }

    /// Turns off what a mode conflicts with before its session setup. Runs inside the mode
    /// change's session work, so nothing here may wait on another session task.
    func resolveConflicts(entering target: Mode) async {
        let isBurst = target == .photo && burstEnabled
        var change = SettingChange(isBurst ? "BURST" : target.label)
        if target == .live || target == .portrait || isBurst {
            await turnOffMaxDimensions(recording: &change, because: "the 48 MP format has no Live Photo movie or depth")
        }
        if camera.state.isCinematicVideoCaptureEnabled, let reason = Self.cinematicConflict(with: target) {
            await turnOffCinematicVideo(recording: &change, because: reason)
        }
        switch target {
        case .live:
            await returnToAutoExposure(recording: &change, because: "Live Photo keeps exposure automatic")
        case .portrait where isManualExposure(camera.state):
            await camera.setExposureMode(.continuousAutoExposure)
            change.turnedOff("manual exposure", because: "a manual capture carries no depth")
        default:
            break
        }
        toaster.gaveWay(change)
    }

    /// Turns Max Dimensions off for BURST, which keeps the PHOTO mode (so no mode setup runs).
    func resolveBurstConflict() async {
        var change = SettingChange("BURST")
        await turnOffMaxDimensions(recording: &change, because: "the 48 MP format has no Live Photo movie or depth")
        toaster.gaveWay(change)
    }

    // MARK: - Making room

    private func makeRoom(for setting: StudioSetting, recording change: inout SettingChange) async {
        let state = camera.state
        switch setting {
        case .maxDimensions:
            if mode == .live || mode == .portrait || burstEnabled {
                change.turnedOff(burstEnabled ? "BURST" : mode.label, because: "the 48 MP format has no Live Photo movie or depth")
                await select(.photo, .standard, for: change.setting)
            }
            await turnOffCinematicVideo(recording: &change, because: "Cinematic Video uses its own video format")
            await returnToAutoExposure(recording: &change, because: "manual photos are 12 MP")
        case .manualExposure, .whiteBalanceLock:
            let isExposure = if case .manualExposure = setting { true } else { false }
            await turnOffMaxDimensions(recording: &change, because: "manual photos are 12 MP")
            await turnOffCinematicVideo(recording: &change, because: Self.cinematicKeepsAuto)
            if mode == .live {
                change.turnedOff("LIVE", because: "Live Photo keeps exposure automatic")
                await select(.photo, .standard, for: change.setting)
            } else if isExposure, mode == .portrait {
                change.turnedOff("PORTRAIT", because: "a manual capture carries no depth")
                await select(.photo, .standard, for: change.setting)
            } else {
                await leavePortraitForWideCamera(recording: &change)
            }
        case .manualFocus:
            await turnOffCinematicVideo(recording: &change, because: "Cinematic Video controls focus")
            await leavePortraitForWideCamera(recording: &change)
        case .focusMode, .subjectTracking:
            await turnOffCinematicVideo(recording: &change, because: "Cinematic Video controls focus")
        case .cinematicVideo:
            await turnOffMaxDimensions(recording: &change, because: "Cinematic Video uses its own video format")
            if state.isContinuousAutoFocusTrackingEnabled {
                await modernControls.turnOffSubjectTracking()
                change.turnedOff("Subject Tracking", because: "Cinematic Video controls focus")
            }
            // VIDEO first, while a manual exposure still keeps its setup from leaving the
            // wide camera a manual control moved to.
            if Self.cinematicConflict(with: mode) != nil {
                change.turnedOff(mode.label, because: "Cinematic Video records in VIDEO")
                await select(.video, .video30, for: change.setting)
            }
            await returnToAutoExposure(recording: &change, because: Self.cinematicKeepsAuto)
            // Cinematic Video moves to the camera that runs it and back when it's turned off,
            // so from the wide camera go back to the usual one first. Where the wide camera
            // runs Cinematic Video itself (an iPhone 18 Pro Max's does), stay: the round trip would only
            // hop back. Turning Cinematic Video off then restores the usual camera.
            if camera.device?.supportsCinematicVideo != true {
                await restoreVirtualCameraIfFullyAuto()
            }
        }
        if setting.needsWideCamera, needsWideCameraForManual, camera.state.isPrimaryConstituentLocked {
            await modernControls.releaseLensLock()
            change.turnedOff("Lens Lock", because: "manual controls run on the wide camera")
        }
    }

    // MARK: - Turning things off

    /// PORTRAIT off before a white balance or focus change moves a virtual camera (the one
    /// PORTRAIT streams depth from) to the wide camera, which has no depth. A physical camera
    /// with depth (TrueDepth) takes the change in place and keeps PORTRAIT.
    private func leavePortraitForWideCamera(recording change: inout SettingChange) async {
        guard mode == .portrait, needsWideCameraForManual else { return }
        change.turnedOff("PORTRAIT", because: "manual controls run on the wide camera, which has no depth")
        await select(.photo, .standard, for: change.setting)
    }

    private func turnOffMaxDimensions(recording change: inout SettingChange, because reason: String) async {
        guard drawerControls.capMaxDimensions else { return }
        await drawerControls.turnOffMaxDimensions()
        change.turnedOff("Max Dimensions", because: reason)
    }

    private func turnOffCinematicVideo(recording change: inout SettingChange, because reason: String) async {
        guard camera.state.isCinematicVideoCaptureEnabled else { return }
        await modernControls.turnOffCinematicVideo()
        change.turnedOff("Cinematic Video", because: reason)
    }

    /// Back to continuous auto exposure and white balance where they're manual or locked.
    private func returnToAutoExposure(recording change: inout SettingChange, because reason: String) async {
        let state = camera.state
        if isManualExposure(state) {
            await camera.setExposureMode(.continuousAutoExposure)
            change.turnedOff("manual exposure", because: reason)
        }
        if state.whiteBalanceMode == .locked {
            await camera.setWhiteBalanceMode(.continuousAutoWhiteBalance)
            change.turnedOff("locked white balance", because: reason)
        }
    }

    private func isManualExposure(_ state: PRMCameraState) -> Bool {
        state.exposureMode == .custom || state.exposureMode == .locked
    }

    /// Selects a mode the way a picker tap does, for `setting`, and waits for its session
    /// setup.
    private func select(_ primary: ModePicker.Primary, _ variant: ModePicker.Variant, for setting: String) async {
        modePicker.select(primary: primary, variant: variant)
        applyPickerSelection(primary: primary, variant: variant, for: setting)
        await sessionTask?.value
    }

    /// Studio runs Cinematic Video with automatic exposure and white balance, like the system
    /// Camera's Cinematic mode.
    private static let cinematicKeepsAuto = "Cinematic Video keeps exposure and white balance automatic"

    /// Why Cinematic Video can't stay on in `mode`, or `nil` when it can.
    private static func cinematicConflict(with mode: Mode) -> String? {
        switch mode {
        // A photo taken with Cinematic Video on comes from its video format: 16:9 at about
        // 9 MP on a 2026-10-08 device run.
        case .photo: "photos would come from Cinematic Video's 16:9 video format"
        case .live: "Live Photo can't record beside Cinematic Video's movie output"
        case .portrait: "Portrait needs the depth stream Cinematic Video takes over"
        case .night: "Night needs manual exposure on the wide camera"
        case .slowMo: "slow motion needs its own frame rate"
        case .video: nil
        }
    }
}
