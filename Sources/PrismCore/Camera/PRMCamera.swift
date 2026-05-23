@preconcurrency import AVFoundation
import CoreMedia

/// MainActor facade over ``PRMCameraSession``.
///
/// Exposes camera operations as `async` methods and state changes as
/// `AsyncStream<PRMCameraState>` for UI binding without manual `DispatchQueue.main` hops.
///
/// ```swift
/// let camera = PRMCamera()
/// try await camera.configure(PRMCameraConfiguration())
/// await camera.start()
///
/// // Bind UI to state changes
/// Task {
///     for await state in camera.stateStream() {
///         label.text = "ISO \(Int(state.iso))"
///     }
/// }
/// ```
@MainActor
public final class PRMCamera {
    // MARK: - Properties

    /// Internal notification name posted from `setExposureModeCustom` /
    /// `setWhiteBalanceModeLocked` completion handlers. `installObservers` wires this
    /// to `refreshState` on MainActor, so the state stream sees AVFoundation's
    /// committed values without us having to cross the `@MainActor` ↔ `@Sendable`
    /// boundary with `weak self` from the completion-handler closure.
    nonisolated static let deviceCommitNotification = Notification.Name("com.luminoid.Prism.deviceCommit")

    /// Underlying session — escape hatch for advanced AVFoundation work.
    public let session: PRMCameraSession

    /// Snapshot of the active device's capabilities. `nil` before ``configure(_:)`` succeeds.
    public private(set) var device: PRMCameraDevice?

    /// Most recent observed state. Updated by ``refreshState()`` and by mutation methods.
    /// The setter is `internal` (not `private(set)`) so the observer extension in
    /// ``PRMCamera+Observers.swift`` can update interruption / running flags from
    /// notification callbacks; external consumers still see a read-only surface.
    public internal(set) var state = PRMCameraState()

    /// Subscriber registries for the three async streams exposed by this camera.
    /// See ``PRMStreamRegistry`` for the cleanup contract — registry's deinit finishes
    /// outstanding subscribers, so this class's deinit can stay minimal. `internal`
    /// rather than `private` so the observer-installation extension in
    /// ``PRMCamera+Observers.swift`` can yield into them.
    let stateStreams = PRMStreamRegistry<PRMCameraState>()
    let errorStreams = PRMStreamRegistry<PRMSessionError>()
    let interruptionStreams = PRMStreamRegistry<Bool>()

    /// KVO and `NotificationCenter` registrations installed by ``installObservers()``.
    /// `internal` so the same extension can append/invalidate them.
    var keyValueObservations: [NSKeyValueObservation] = []
    var notificationObservers: [any NSObjectProtocol] = []

    // User-driven mode intents that override AVFoundation's lagging device
    // reads during the ~3 s window between the slider-driven setter call and
    // its completion handler firing (per Apple dev-forum 751112). Without
    // these, the 500 ms telemetry tick reads the stale mid-flight mode and
    // the UI flips back to "(auto)" mid-drag — the user-visible "slider
    // jumped back to auto" symptom. Cleared the moment the device commits
    // (mode matches the intent), or when the user explicitly picks a new mode.
    private var intendedExposureMode: AVCaptureDevice.ExposureMode?
    private var intendedWhiteBalanceMode: AVCaptureDevice.WhiteBalanceMode?

    /// User-intent snapshot for the manual exposure values, exposed so the
    /// photo-capture layer can patch the saved photo's EXIF without racing
    /// the device's lagging `iso` / `exposureDuration` properties. Returns
    /// `nil` when the user isn't in custom exposure mode. Caller is
    /// responsible for using this only when capturing in a manual context.
    /// Snapshot the user-driven manual exposure values for callers that need
    /// to mirror them into a downstream API (e.g. `PRMPhotoCapture`'s EXIF
    /// patch path). Returns `nil` in continuous-auto modes.
    ///
    /// Reads `state.exposureMode == .custom` as the source-of-truth for "is
    /// the user in manual exposure?" — NOT the transient `intendedExposureMode`
    /// flag. The intent flags are auto-cleared in `refreshState` once the
    /// device-reported values catch up to the user's slider input. That's
    /// correct for UI stickiness (slider can free-drag once AVF lands) but
    /// wrong for "should I patch the EXIF as manual?" — the device is still
    /// in `.custom` after the intent flag clears, and the values to use are
    /// `state.iso` / `state.exposureDurationSeconds`. Falls back to the
    /// intent values when state lags (race: just after `setCustomExposure`,
    /// before `refreshState` catches up).
    public var currentManualExposureSnapshot: (iso: Float, duration: CMTime)? {
        let isManual = state.exposureMode == .custom || intendedExposureMode == .custom
        guard isManual else { return nil }
        let iso = intendedISO ?? state.iso
        let durationSeconds = intendedExposureDurationSeconds ?? state.exposureDurationSeconds ?? 0
        guard iso > 0, durationSeconds > 0, durationSeconds.isFinite else { return nil }
        let duration = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: 1_000_000)
        return (iso, duration)
    }

    /// User-set ISO that should be honored by ``state``.iso until AVFoundation
    /// commits and the device-reported `iso` matches. Without this, the 500 ms
    /// telemetry tick reads the stale auto-driven `device.iso` after the user
    /// releases the slider and the value visibly snaps back — the
    /// "ISO jumped back" symptom that survived the exposure-mode override.
    private var intendedISO: Float?
    /// User-set exposure duration (seconds) honored by
    /// ``state``.exposureDurationSeconds until AVFoundation commits.
    private var intendedExposureDurationSeconds: Double?
    /// User-set WB Kelvin honored by ``state``.whiteBalanceTemperature until
    /// AVFoundation commits the locked WB gains.
    private var intendedWhiteBalanceTemperature: Float?
    /// Auto-exposure ISO baseline snapshotted whenever the device is in
    /// continuous / auto exposure (and the user isn't actively driving sliders).
    /// Used as the reference point for the Tv/Av-priority reciprocity math in
    /// ``setISO(_:)`` and ``setShutterSpeed(seconds:)`` so the OTHER axis can
    /// be adjusted to preserve the auto-metered light value when one axis is
    /// changed by the user.
    private var autoExposureBaselineISO: Float?
    private var autoExposureBaselineDurationSeconds: Double?

    // MARK: - Init

    public init(session: PRMCameraSession? = nil) {
        self.session = session ?? PRMCameraSession.makeDefaultMainActor()
        // All `intended*` and `autoExposure*` properties are optional and Swift
        // initializes them to nil by default — no need to re-assign here.
    }

    deinit {
        for obs in keyValueObservations {
            obs.invalidate()
        }
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        // PRMStreamRegistry's own deinit finishes outstanding subscribers; no explicit
        // teardown needed here.
    }

    // MARK: - Lifecycle

    /// Configures the session and refreshes ``device`` + ``state``.
    public func configure(_ configuration: PRMCameraConfiguration) async throws {
        PRMLogger.trace(.session, "PRMCamera.configure")
        // Reconfigure clears any per-session manual-exposure / WB intents — the
        // new session starts in `.continuousAuto` for both axes, and we don't
        // want a stale intent from before configure to keep overriding the read.
        clearIntendedState()
        try await session.configure(configuration)
        await refreshDevice()
        await refreshState()
        await installObservers()
    }

    /// Starts the session. Idempotent.
    public func start() async {
        PRMLogger.trace(.session, "PRMCamera.start")
        await session.start()
        await refreshState()
    }

    /// Stops the session. Idempotent.
    public func stop() async {
        PRMLogger.trace(.session, "PRMCamera.stop")
        await session.stop()
        await refreshState()
    }

    /// Switches the camera position and refreshes ``device``.
    public func switchCamera(to position: AVCaptureDevice.Position) async throws {
        PRMLogger.trace(.session, "PRMCamera.switchCamera(\(position.rawValue))")
        // The new physical device starts in `.continuousAuto` — drop intents so
        // the override doesn't keep painting the old custom state on the new lens.
        clearIntendedState()
        _ = try await session.switchCamera(to: position)
        // Wait for AVF's async pipeline rebuild to settle before returning, so the
        // consuming app's follow-up mutations (mode-change handlers that toggle
        // Live Photo / movie output) don't land on an in-flight rebuild — which on
        // virtual devices leaves `captureReadiness` permanently stuck at
        // `.notReadyMomentarily`. See `PRMCameraSession.awaitPhotoOutputReady`.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshDevice()
        await refreshState()
    }

    /// Switches to a specific physical device type (optionally at a different position).
    /// See ``PRMCameraSession/switchDevice(type:position:)`` for the rationale — primarily
    /// hopping to `.builtInWideAngleCamera` to access slo-mo formats that the virtual
    /// `.builtInTripleCamera` device doesn't expose.
    public func switchDevice(
        type: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position? = nil
    ) async throws {
        PRMLogger.trace(.session, "PRMCamera.switchDevice(type=\(type.rawValue), pos=\(position?.rawValue.description ?? "nil"))")
        clearIntendedState()
        _ = try await session.switchDevice(type: type, position: position)
        // See `switchCamera` for the readiness-wait rationale.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshDevice()
        await refreshState()
    }

    /// Toggle the movie file output between video-recording mode (attached, Live Photo
    /// unavailable) and Live-Photo-capable mode (detached). See
    /// ``PRMCameraSession/setMovieFileOutputAttached(_:)`` for the rationale.
    /// Toggle the photo output's attachment to the session. Use when entering a
    /// stills-incompatible workflow that's bumping the ISP budget (e.g. 240 fps
    /// slo-mo with movie output attached, which triggers `AVError -11872 "Cannot
    /// Record"`). See ``PRMCameraSession/setPhotoOutputAttached(_:)`` for the
    /// full rationale. Consumers must rebuild cached ``PRMPhotoCapture``
    /// wrappers after re-attach (the new photo output is a fresh instance).
    public func setPhotoOutputAttached(_ attached: Bool) async throws {
        PRMLogger.trace(.session, "PRMCamera.setPhotoOutputAttached(\(attached))")
        try await session.setPhotoOutputAttached(attached)
        // Attach/detach is a session begin/commit; wait for AVF's async pipeline
        // rebuild before returning. See `switchCamera` for the rationale.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
    }

    /// Toggle the movie file output between video-recording mode (attached, Live
    /// Photo unavailable) and Live-Photo-capable mode (detached). Optional
    /// `targetLivePhoto:` lets the caller bake the desired Live Photo state into
    /// the same begin/commit — strongly recommended when entering a mode that
    /// doesn't want Live Photo (e.g. NIGHT, PORTRAIT) to avoid the back-to-back
    /// toggle storm that strands the secondary movie pipeline on virtual devices.
    /// See ``PRMCameraSession/setMovieFileOutputAttached(_:targetLivePhoto:)`` for
    /// the full rationale.
    public func setMovieFileOutputAttached(_ attached: Bool, targetLivePhoto: Bool? = nil) async throws {
        PRMLogger.trace(
            .session,
            "PRMCamera.setMovieFileOutputAttached(\(attached), targetLivePhoto=\(targetLivePhoto.map(String.init(describing:)) ?? "nil"))"
        )
        try await session.setMovieFileOutputAttached(attached, targetLivePhoto: targetLivePhoto)
        // Movie-output attach/detach toggles `isLivePhotoCaptureEnabled` as a
        // mutual-exclusion side-effect, which kicks off AVF's lengthy capture
        // render pipeline rebuild. Wait for it to settle before returning so the
        // consuming app's next mutation doesn't pile up on the in-flight rebuild.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
    }

    /// Runtime toggle for Live Photo capability on the photo output. See
    /// ``PRMCameraSession/setLivePhotoCaptureEnabled(_:)`` — flip this off before
    /// entering manual exposure (custom ISO / shutter / WB lock) and back on when the
    /// user returns to auto exposure with Live Photo capture intended.
    public func setLivePhotoCaptureEnabled(_ enabled: Bool) async {
        PRMLogger.trace(.session, "PRMCamera.setLivePhotoCaptureEnabled(\(enabled))")
        await session.setLivePhotoCaptureEnabled(enabled)
        // The Live Photo toggle is exactly the trigger Apple documents as requiring
        // "a lengthy reconfiguration of the capture render pipeline." Wait for AVF
        // to finish that rebuild before returning — see `switchCamera` for the
        // pipeline-stack-up rationale.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
    }

    /// Promotes the device's `activeFormat` to the format with the largest landscape
    /// `supportedMaxPhotoDimensions` — typically the 48MP format on iPhone 14 Pro+ /
    /// 15 Pro+ wide camera. Also raises the photo output's `maxPhotoDimensions` ceiling.
    ///
    /// **Mutually exclusive with Live Photo capture** — the 48MP photo format doesn't
    /// stream the parallel movie pipeline Live Photo requires. Disable Live Photo before
    /// calling this; re-enable Live Photo (which itself restores a compatible format)
    /// when reverting to standard-resolution capture.
    ///
    /// On virtual devices (`triple`, `dual`, `dualWide`) this is a no-op — virtual
    /// devices cap at 12MP regardless of format selection. Swap to
    /// `.builtInWideAngleCamera` via ``switchDevice(type:position:)`` first.
    public func setHighResolutionPhotoFormat(_ enabled: Bool) async {
        PRMLogger.trace(.session, "PRMCamera.setHighResolutionPhotoFormat(\(enabled))")
        if enabled {
            // Log a single .warning before we even touch the session if the active
            // device is virtual. The format-swap helpers below will scan device.formats
            // and pick the "best" one regardless, but virtual devices' formats cap at
            // 12MP — the promotion is a silent no-op and the caller will wonder why
            // captures stay at 12MP. Surface the cause once, here, with the fix path
            // (`switchDevice(type: .builtInWideAngleCamera)`).
            let isVirtual = await PRMCameraActor.shared.run { [session] in
                await session.videoDevice?.prm_isVirtualMultiCameraDevice ?? false
            }
            if isVirtual {
                PRMLogger.session.warning(
                    """
                    setHighResolutionPhotoFormat(true) called on a virtual multi-camera device — \
                    virtual devices (.builtInTripleCamera / .builtInDualCamera / .builtInDualWideCamera) \
                    cap at 12MP regardless of activeFormat. The promotion will silently no-op. \
                    Call switchDevice(type: .builtInWideAngleCamera) first to access 48MP capture.
                    """
                )
            }
        }
        await PRMCameraActor.shared.run { [session] in
            if enabled {
                await session.applyHighResolutionPhotoFormat()
            } else {
                await session.applyLivePhotoCompatibleFormat()
            }
        }
        // Format swap with aux-flag reconciliation is a session begin/commit;
        // wait for AVF's async pipeline rebuild before returning. See `switchCamera`.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshDevice()
        await refreshState()
    }

    // MARK: - Device controls (forward to AVCaptureDevice extensions on actor)

    public func setZoom(_ factor: CGFloat) async {
        await runOnDevice { try? $0.prm_setZoom(factor) }
        await refreshState()
    }

    public func rampZoom(to factor: CGFloat, rate: Float = 1.0) async {
        await runOnDevice { try? $0.prm_rampZoom(to: factor, rate: rate) }
    }

    public func cancelZoomRamp() async {
        await runOnDevice { try? $0.prm_cancelZoomRamp() }
    }

    public func setTorch(_ mode: AVCaptureDevice.PRMTorchMode) async {
        await runOnDevice { try? $0.prm_setTorch(mode) }
        await refreshState()
    }

    public func setExposureBias(_ bias: Float) async {
        await runOnDevice { try? $0.prm_setExposureBias(bias) }
        await refreshState()
    }

    public func setExposureMode(_ mode: AVCaptureDevice.ExposureMode) async {
        PRMLogger.trace(.session, "PRMCamera.setExposureMode(\(mode.rawValue))")
        // User explicitly picked a mode — drop any prior manual-exposure intent
        // so the UI doesn't keep showing "custom" after the user taps auto.
        intendedExposureMode = mode
        // Returning to any auto path also drops the pinned ISO / duration
        // values so the slider labels start tracking the auto-driven readings
        // again. The baseline reset happens implicitly via `refreshState`
        // re-snapshotting once the device settles back into auto.
        if mode != .custom {
            intendedISO = nil
            intendedExposureDurationSeconds = nil
        }
        await runOnDevice { try? $0.prm_setExposureMode(mode) }
        await refreshState()
    }

    public func setCustomExposure(duration: CMTime, iso: Float) async {
        PRMLogger.trace(
            .session,
            "PRMCamera.setCustomExposure(duration=\(CMTimeGetSeconds(duration))s, iso=\(iso))"
        )
        intendedExposureMode = .custom
        // Snapshot the user-requested values so `refreshState` keeps the UI
        // pinned to what they set, not the lagging device-reported pre-commit
        // values. Sentinel `currentISO` / `currentExposureDuration` mean "keep
        // current" — don't write those into the intent, otherwise the slider
        // would freeze on the sentinel marker instead of the real current value.
        if iso != AVCaptureDevice.currentISO {
            intendedISO = iso
        }
        if duration.isValid, duration != AVCaptureDevice.currentExposureDuration {
            let seconds = CMTimeGetSeconds(duration)
            if seconds > 0, seconds.isFinite {
                intendedExposureDurationSeconds = seconds
            }
        }
        // `setExposureModeCustom` is asynchronous — its completion handler fires
        // when AVFoundation accepts the new mode + values, which can take up to
        // ~3 s on long shutter durations (per Apple dev-forum 751112). Reading
        // `device.exposureMode` immediately after the call returns reads the
        // pre-change mode, so the row's label briefly shows "(auto)". Post a
        // notification from the completion handler — captured `self` would have
        // to cross the Sendable closure boundary, which `@MainActor` PRMCamera
        // can't safely do. NotificationCenter is the clean bridge: the observer
        // is installed in `installObservers()` and routes to `refreshState` on
        // MainActor. We DON'T await the completion inline — continuous slider
        // drags fire `setCustomExposure` 30+ times/sec, and awaiting each ~100 ms
        // commit would serialize the actor into a multi-second stall.
        let thrown = await runOnDeviceThrowing { device in
            try device.prm_setCustomExposure(duration: duration, iso: iso) { _ in
                NotificationCenter.default.post(name: Self.deviceCommitNotification, object: nil)
            }
        }
        if let sessionError = thrown as? PRMSessionError {
            // Surface the virtual-device-rejection error (or any future PRMSessionError
            // the device helper starts throwing) on the errorStream so consumers know
            // their manual command was silently dropped at the device layer.
            emitError(sessionError)
        }
        await refreshState()
    }

    public func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) async {
        PRMLogger.trace(.session, "PRMCamera.setWhiteBalanceMode(\(mode.rawValue))")
        intendedWhiteBalanceMode = mode
        if mode != .locked {
            intendedWhiteBalanceTemperature = nil
        }
        await runOnDevice { try? $0.prm_setWhiteBalanceMode(mode) }
        await refreshState()
    }

    public func lockWhiteBalance(_ values: AVCaptureDevice.PRMTemperatureAndTint) async {
        PRMLogger.trace(
            .session,
            "PRMCamera.lockWhiteBalance(temp=\(values.temperature), tint=\(values.tint))"
        )
        intendedWhiteBalanceMode = .locked
        intendedWhiteBalanceTemperature = values.temperature
        // Same async-completion handling as `setCustomExposure` — see that doc.
        // Refresh-via-notification keeps continuous Kelvin slider drags fluent
        // while still landing the final "locked" Kelvin after the completion
        // fires. The `intendedWhiteBalanceTemperature` override above keeps
        // `state.whiteBalanceTemperature` pinned to the user's value during
        // the commit window, so the slider doesn't snap back to the old
        // auto-driven Kelvin after the user releases.
        let thrown = await runOnDeviceThrowing { device in
            try device.prm_lockWhiteBalance(values) { _ in
                NotificationCenter.default.post(name: Self.deviceCommitNotification, object: nil)
            }
        }
        if let sessionError = thrown as? PRMSessionError {
            emitError(sessionError)
        }
        await refreshState()
    }

    public func lockWhiteBalance(preset: AVCaptureDevice.PRMWhiteBalancePreset) async {
        await lockWhiteBalance(
            AVCaptureDevice.PRMTemperatureAndTint(temperature: preset.temperature, tint: 0)
        )
    }

    public func setFrameRate(_ fps: Float64, allowFormatChange: Bool = true) async {
        PRMLogger.trace(.session, "PRMCamera.setFrameRate(\(fps), allowFormatChange=\(allowFormatChange))")
        // Whole transition (preset switch + format swap + movie-output re-attach) runs
        // inside ONE `PRMCameraActor.shared.run` block so the actor stays exclusively
        // held across all three steps. Without that, an external shutter tap can hop
        // onto the actor between our `setMovieFileOutputAttached(false)` and
        // `(true)` calls and observe `movieFileOutput == nil` — the user-visible
        // symptom is `PRMVideoRecorder.start` failing with "is not attached to the
        // session" right after the user just enabled slo-mo.
        //
        // **Critical preset rule**: `AVCaptureSession.Preset.photo` (and most other
        // named presets) imposes session-level constraints that REJECT non-matching
        // `activeFormat` choices. When a custom format is active under `.photo`,
        // AVFoundation silently invalidates `AVCaptureMovieFileOutput`'s video
        // connection — `output.connection(with: .video)` returns `nil` even though
        // the output is still in `session.outputs`. This is the documented behavior
        // since iOS 7 (see Apple dev-forum thread 87110 and the high-frame-rate API
        // docs): *"If you don't manually set captureSession.sessionPreset to
        // .inputPriority, your captured FPS will be the default, and setting
        // device.activeVideoMinFrameDuration / activeVideoMaxFrameDuration won't
        // have any effects."*
        //
        // The fix is to switch the session preset to `.inputPriority` for any
        // `setFrameRate` call that's allowed to change format. The preset switch +
        // format change happen inside the same `beginConfiguration` /
        // `commitConfiguration` so AVF sees them atomically.
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return }
            let avSession = session.session
            let movieAttachedBefore = await session.movieFileOutput != nil

            avSession.beginConfiguration()
            // Relax to input-priority BEFORE the format swap. Skip the preset write
            // if we're already there to avoid log noise and AVF re-validation churn.
            if allowFormatChange, avSession.sessionPreset != .inputPriority {
                if avSession.canSetSessionPreset(.inputPriority) {
                    PRMLogger.session.notice(
                        "setFrameRate: switching sessionPreset \(avSession.sessionPreset.rawValue, privacy: .public) → inputPriority to allow custom format"
                    )
                    avSession.sessionPreset = .inputPriority
                } else {
                    PRMLogger.session.warning(
                        "setFrameRate: session does not support .inputPriority preset; format swap may invalidate AVCaptureMovieFileOutput connection"
                    )
                }
            }
            let change = try? device.prm_setFrameRate(fps, allowFormatChange: allowFormatChange)
            avSession.commitConfiguration()

            // Even with the `.inputPriority` preset switch, AVFoundation tears down
            // `AVCaptureMovieFileOutput`'s video connection during the `activeFormat`
            // swap and the same-instance rebuild doesn't always restore an active
            // connection. Detach + re-attach forces a fresh output instance whose
            // video connection is built from scratch against the now-current
            // `activeFormat`. The detach/reattach has to happen inside the SAME
            // actor block so an external shutter tap can't race into the gap and
            // observe a transiently missing output. Both setters do their own
            // session begin/commit; nesting them under the same actor hold is fine
            // (the begin/commit pairs are sequential, not nested).
            let didChangeFormat = change?.formatChanged ?? false
            if movieAttachedBefore, didChangeFormat {
                PRMLogger.session.notice("setFrameRate: format changed — re-attaching movieFileOutput against new active format")
                try? await session.setMovieFileOutputAttached(false)
                try? await session.setMovieFileOutputAttached(true)
            }
        }
        // Wait for AVF's async pipeline rebuild to settle so the next consumer
        // call doesn't stack a mutation onto an in-flight rebuild. The preset
        // switch + format swap + (optional) movie-output cycle all trigger the
        // "lengthy reconfiguration of the capture render pipeline" Apple docs
        // for `isLivePhotoCaptureEnabled`. See `switchCamera` for the rationale.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshState()
    }

    public func resetFrameRate() async {
        PRMLogger.trace(.session, "PRMCamera.resetFrameRate")
        // Restore the session preset that was active at `configure(_:)` time AND
        // clear the device's custom min/max frame duration. `setFrameRate(_:)`
        // may have switched the preset to `.inputPriority` for slo-mo; leaving the
        // session in input-priority mode when the consuming app returns to a photo
        // workflow can leave `AVCapturePhotoOutput` without an active video
        // connection — the next `capturePhoto` call then crashes with an uncaught
        // `NSInvalidArgumentException: No active and enabled video connection`.
        // Restoring the documented preset re-validates every output against the
        // preset's rules and rebuilds the photo output's connection.
        //
        // The restore is best-effort: if `canSetSessionPreset` returns false on
        // the current device (e.g. portrait-only formats after `enableDepthFormat`
        // that aren't `.photo`-preset-compatible), we leave the preset alone and
        // log a warning rather than crashing.
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return }
            let avSession = session.session
            let originalPreset = await session.configuredSessionPreset
            avSession.beginConfiguration()
            if let originalPreset, avSession.sessionPreset != originalPreset {
                if avSession.canSetSessionPreset(originalPreset) {
                    PRMLogger.session.notice(
                        "resetFrameRate: restoring sessionPreset \(avSession.sessionPreset.rawValue, privacy: .public) → \(originalPreset.rawValue, privacy: .public)"
                    )
                    avSession.sessionPreset = originalPreset
                } else {
                    PRMLogger.session.warning(
                        "resetFrameRate: cannot restore sessionPreset \(originalPreset.rawValue, privacy: .public) on current device — staying on \(avSession.sessionPreset.rawValue, privacy: .public)"
                    )
                }
            }
            try? device.prm_resetFrameRate()
            avSession.commitConfiguration()
        }
        // The preset restore is a session begin/commit; wait for AVF's async
        // pipeline rebuild to settle before returning. See `switchCamera`.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshState()
    }

    /// Switches `activeFormat` + `activeDepthDataFormat` to a depth-capable pair so
    /// portrait/bokeh captures actually receive a populated depth buffer. Some session
    /// presets (notably `.photo` on iPhone Pro models) pick a non-depth-streaming
    /// format by default; without this call, depth ancillaries arrive with internally
    /// null `depthDataMap` buffers. Returns `true` if a depth format is now active.
    ///
    /// There is intentionally no `disableDepthFormat()` counterpart. Setting
    /// `activeDepthDataFormat = nil` while `AVCapturePhotoOutput.isDepthDataDeliveryEnabled`
    /// is on (which it is for the whole session in our default configuration) throws
    /// `NSInvalidArgumentException` at runtime. The cost of leaving depth streaming
    /// enabled outside Portrait mode is small (one ISP channel, no measurable preview
    /// impact), and the format change is sticky for the session — re-entering Portrait
    /// is a cheap no-op after the first call.
    @discardableResult
    public func enableDepthFormat() async -> Bool {
        PRMLogger.trace(.session, "PRMCamera.enableDepthFormat")
        let result = await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return false }
            // The format change must be wrapped in `beginConfiguration` /
            // `commitConfiguration` at the session level — not just the device-lock —
            // because the photo output validates its delivery flags (depth, portrait
            // matte) against the active format at commit time. Without the session
            // wrap, the output is left with stale validation and depth captures arrive
            // as `AVDepthData` instances whose `depthDataMap` is internally null.
            let avSession = session.session
            avSession.beginConfiguration()
            let didEnable = (try? device.prm_enableDepthFormat()) ?? false
            // Re-toggle the photo output's delivery flags so it re-validates them
            // against the now-current `activeFormat` + `activeDepthDataFormat`. Without
            // this, the flags set at `attachPhotoOutput` time stay "enabled" but
            // AVFoundation never actually wires depth to the photo capture path —
            // captures complete with `depthData != nil` but a null `depthDataMap`.
            // The toggle-off/toggle-on dance forces the re-validation; just leaving
            // them on is not sufficient.
            if didEnable, let photoOutput = await session.photoOutput {
                #if !os(macOS)
                    if photoOutput.isDepthDataDeliverySupported {
                        photoOutput.isDepthDataDeliveryEnabled = false
                        photoOutput.isDepthDataDeliveryEnabled = true
                    }
                    if photoOutput.isPortraitEffectsMatteDeliverySupported {
                        photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
                        photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
                    }
                #endif
            }
            avSession.commitConfiguration()
            return didEnable
        }
        // Depth-format swap + depth/matte flag re-toggle is a session begin/commit;
        // wait for AVF's async pipeline rebuild before returning. See `switchCamera`.
        #if !os(macOS)
            _ = await session.awaitPhotoOutputReady()
        #endif
        await refreshState()
        return result
    }

    public func setFocusAndExposure(
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        at devicePoint: CGPoint,
        monitorSubjectAreaChange: Bool = false
    ) async {
        intendedExposureMode = exposureMode
        await runOnDevice {
            try? $0.prm_setFocusAndExposure(
                focusMode: focusMode,
                exposureMode: exposureMode,
                at: devicePoint,
                monitorSubjectAreaChange: monitorSubjectAreaChange
            )
        }
        await refreshState()
    }

    public func setStabilization(_ mode: AVCaptureVideoStabilizationMode) async {
        await PRMCameraActor.shared.run {
            if let connection = await self.session.videoDataOutput?.connection(with: .video) {
                connection.prm_setStabilization(mode)
            }
            if let connection = await self.session.movieFileOutput?.connection(with: .video) {
                connection.prm_setStabilization(mode)
            }
        }
        await refreshState()
    }

    /// Locks focus at the given lens position (0 = near, 1 = far). Returns after the
    /// physical lens move completes.
    public func setLensPosition(_ position: Float) async {
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return }
            try? await device.prm_setLensPosition(position)
        }
        await refreshState()
    }

    /// Sets manual ISO and auto-updates shutter to preserve the auto-metered
    /// light value (Tv/Av-priority style). When `autoExposureBaselineISO` and
    /// `autoExposureBaselineDurationSeconds` are present (snapshotted while
    /// the device was in continuous-auto, before the user entered custom),
    /// the new duration is computed via classic reciprocity:
    ///   `newDuration = baselineDuration × (baselineISO / newISO)`
    /// so that `ISO × duration` (the light value, LV) stays at the
    /// auto-metered product. If the computed duration falls outside the
    /// active format's `[minExposureDuration, maxExposureDuration]` window,
    /// it's clamped — and the user's requested ISO is also re-derived from
    /// the clamped duration to preserve LV exactly. Without this dual-clamp
    /// step, the slider would land at e.g. ISO 1667 + clamped duration 1/3s,
    /// and the saved EV would silently drift from the metered target.
    ///
    /// If no baseline exists yet (cold launch with no auto frame), fall back
    /// to `AVCaptureDevice.currentExposureDuration` — better than randomly
    /// guessing.
    /// User drags ISO → ISO is the **fixed** axis; duration is derived from
    /// the LV target. Clamping ISO to the device range honors the user's
    /// intent (the slider was set there); the derived duration also clamps
    /// to the device's `[minExposureDuration, maxExposureDuration]`.
    ///
    /// Returns the user's exact ISO when in range, or the closest device-
    /// supported ISO + the clamped reciprocal duration when out of range. LV
    /// may drift only when the device envelope physically can't represent
    /// the target product — the alternative would be to silently re-derive
    /// the user's slider value to keep LV, which the user explicitly didn't
    /// ask for.
    public func setISO(_ iso: Float, baseline: (iso: Float, durationSeconds: Double)? = nil) async {
        let resolvedBaseline = baseline.flatMap { override in
            (override.iso > 0 && override.durationSeconds > 0) ? override : nil
        } ?? autoExposureBaselineISO.flatMap { snap in
            autoExposureBaselineDurationSeconds.map { (iso: snap, durationSeconds: $0) }
        }
        guard let resolvedBaseline, resolvedBaseline.iso > 0, iso > 0 else {
            await setCustomExposure(duration: AVCaptureDevice.currentExposureDuration, iso: iso)
            return
        }
        let targetLV = Double(resolvedBaseline.iso) * resolvedBaseline.durationSeconds
        let (finalISO, finalDuration) = await Self.reciprocity(
            fixedISO: iso,
            fixedDurationSeconds: nil,
            targetLV: targetLV,
            session: session
        )
        let durationCM = CMTimeMakeWithSeconds(finalDuration, preferredTimescale: 1_000_000)
        await setCustomExposure(duration: durationCM, iso: finalISO)
    }

    /// User drags shutter → shutter is the **fixed** axis; ISO is derived
    /// from the LV target. Same clamping rule as ``setISO(_:)``.
    ///
    /// `baseline` lets the caller pin the reciprocity reference to a snapshot
    /// taken *before* a device switch (e.g. virtual → wide for manual mode).
    /// Without it, callers that swap the device immediately before driving
    /// shutter would compute LV against the post-switch auto-AE baseline,
    /// which meters a different FOV and yields the wrong ISO target.
    public func setShutterSpeed(seconds: Double, baseline: (iso: Float, durationSeconds: Double)? = nil) async {
        let resolvedBaseline = baseline.flatMap { override in
            (override.iso > 0 && override.durationSeconds > 0) ? override : nil
        } ?? autoExposureBaselineISO.flatMap { snap in
            autoExposureBaselineDurationSeconds.map { (iso: snap, durationSeconds: $0) }
        }
        guard let resolvedBaseline, resolvedBaseline.durationSeconds > 0, seconds > 0 else {
            let durationCM = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
            await setCustomExposure(duration: durationCM, iso: AVCaptureDevice.currentISO)
            return
        }
        let targetLV = Double(resolvedBaseline.iso) * resolvedBaseline.durationSeconds
        let (finalISO, finalDuration) = await Self.reciprocity(
            fixedISO: nil,
            fixedDurationSeconds: seconds,
            targetLV: targetLV,
            session: session
        )
        let durationCM = CMTimeMakeWithSeconds(finalDuration, preferredTimescale: 1_000_000)
        await setCustomExposure(duration: durationCM, iso: finalISO)
    }

    /// Compute `(iso, duration)` such that exactly one axis is honored as the
    /// user's fixed input and the other is derived from `targetLV / fixed`.
    /// Both axes are clamped to the active format's supported ranges. Exactly
    /// one of `fixedISO` or `fixedDurationSeconds` must be non-nil.
    ///
    /// Why this can't be a two-pass clamp like the previous helper: when the
    /// user explicitly drags the shutter slider, they expect that exact
    /// shutter value to land — re-deriving shutter from a clamped ISO would
    /// silently move the slider out from under them. So the fixed axis is
    /// only clamped to the device range, never recomputed for LV.
    private static func reciprocity(
        fixedISO: Float?,
        fixedDurationSeconds: Double?,
        targetLV: Double,
        session: PRMCameraSession
    ) async -> (iso: Float, durationSeconds: Double) {
        let bounds: (minISO: Float, maxISO: Float, minDur: Double, maxDur: Double)? =
            await PRMCameraActor.shared.run {
                guard let device = await session.videoDevice else { return nil }
                let format = device.activeFormat
                return (
                    format.minISO,
                    format.maxISO,
                    CMTimeGetSeconds(format.minExposureDuration),
                    CMTimeGetSeconds(format.maxExposureDuration)
                )
            }
        let minISO = bounds?.minISO ?? 1
        let maxISO = bounds?.maxISO ?? .greatestFiniteMagnitude
        let minDur = bounds?.minDur ?? 0
        let maxDur = bounds?.maxDur ?? .greatestFiniteMagnitude

        if let userISO = fixedISO {
            let iso = min(max(userISO, minISO), maxISO)
            let derivedDur = iso > 0 ? targetLV / Double(iso) : maxDur
            let duration = min(max(derivedDur, minDur), maxDur)
            return (iso, duration)
        }
        if let userDuration = fixedDurationSeconds {
            let duration = min(max(userDuration, minDur), maxDur)
            let derivedISO = duration > 0 ? Float(targetLV / duration) : maxISO
            let iso = min(max(derivedISO, minISO), maxISO)
            return (iso, duration)
        }
        return (minISO, minDur)
    }

    /// Enables, disables, or restores auto for video HDR. `nil` returns to auto.
    public func setVideoHDR(_ enabled: Bool?) async {
        await runOnDevice { try? $0.prm_setVideoHDR(enabled) }
        await refreshState()
    }

    /// Enables or disables automatic low-light boost when the device supports it.
    public func setLowLightBoost(_ enabled: Bool) async {
        await runOnDevice { try? $0.prm_setLowLightBoost(enabled) }
        await refreshState()
    }

    // MARK: - Streams

    /// Async stream of state snapshots.
    ///
    /// Yields the current ``state`` immediately on subscribe, then a new value on every
    /// mutation. This is the only stream that yields an initial value — error and
    /// interruption streams only emit on actual events.
    ///
    /// **Subscriber cardinality is unbounded.** Each call creates a fresh stream and
    /// registers its continuation in a ``PRMStreamRegistry``; the entry is removed when
    /// the stream's iterator finishes (via the registry's `onTermination` cleanup).
    /// Typical usage is 1–3 concurrent subscribers (HUD, drawer, telemetry strip). The
    /// registry will grow if subscribers leak their iteration tasks — every `Task {
    /// for await state in camera.stateStream() {...} }` must be stored and cancelled
    /// when the owning view controller goes away, otherwise the continuation stays alive
    /// (and keeps receiving values) until the camera itself deinits.
    public func stateStream() -> AsyncStream<PRMCameraState> {
        stateStreams.makeStream(initial: state)
    }

    /// Async stream of runtime errors emitted by the session.
    ///
    /// Does **not** yield an initial value — there is no "current error" concept. Errors
    /// already in flight before you subscribe are lost; subscribe before
    /// ``configure(_:)``/``start()`` to catch boot-time failures.
    public func errorStream() -> AsyncStream<PRMSessionError> {
        errorStreams.makeStream()
    }

    /// Async stream of interruption events. `true` = interrupted, `false` = resumed.
    ///
    /// Does **not** yield an initial value — to read the current interruption status,
    /// check ``state``.`isInterrupted` directly.
    public func interruptionStream() -> AsyncStream<Bool> {
        interruptionStreams.makeStream()
    }

    // MARK: - State helpers

    /// Re-reads device state and emits a new snapshot.
    public func refreshState() async {
        let snapshot: PRMCameraState? = await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return nil }
            var newState = PRMCameraState()
            newState.isRunning = await session.isRunning
            newState.zoomFactor = device.videoZoomFactor
            newState.torchMode = device.torchMode
            newState.torchLevel = device.torchLevel
            newState.focusMode = device.focusMode
            newState.lensPosition = device.lensPosition
            newState.exposureMode = device.exposureMode
            newState.exposureBias = device.exposureTargetBias
            newState.iso = device.iso
            newState.isVideoHDREnabled = device.activeFormat.isVideoHDRSupported && device.isVideoHDREnabled
            newState.isLowLightBoostActive = device.prm_isLowLightBoostActive
            let durationSeconds = CMTimeGetSeconds(device.exposureDuration)
            newState.exposureDurationSeconds = (durationSeconds > 0 && durationSeconds.isFinite) ? durationSeconds : nil
            newState.whiteBalanceMode = device.whiteBalanceMode
            let tempTint = device.prm_currentTemperatureAndTint()
            newState.whiteBalanceTemperature = tempTint.temperature
            newState.whiteBalanceTint = tempTint.tint
            if let connection = await session.videoDataOutput?.connection(with: .video) {
                newState.activeStabilizationMode = connection.activeVideoStabilizationMode
            }
            newState.frameRate = device.prm_currentFrameRate()
            // `activePrimaryConstituentDevice` is iOS 16+ and only meaningful on a virtual
            // multi-lens device. On single-lens devices it returns `nil` (correct fallback)
            // — the UI then falls back to the switchover-bucket heuristic.
            newState.activePrimaryDeviceType = device.activePrimaryConstituent?.deviceType
            return newState
        }
        guard let snapshot else { return }
        // Preserve the interruption flag — it's tracked via notifications, not by re-reading
        // the device, so a snapshot built from device state alone would always say false.
        var updated = snapshot
        updated.isInterrupted = state.isInterrupted

        // Apply user-intent overrides for exposure mode and WB mode. These bridge
        // the ~3 s window between the slider-driven AVFoundation setter call and
        // its completion handler firing — without them, the 500 ms telemetry
        // tick reads the stale mid-flight mode (`.continuousAutoExposure`) and
        // the UI flips back to "(auto)" mid-drag. Clear the intent the moment
        // the device has actually committed (mode matches) so future auto
        // recovery via `setExposureMode(.continuousAuto)` works without lag.
        if let intent = intendedExposureMode {
            if updated.exposureMode == intent {
                intendedExposureMode = nil
            } else {
                updated.exposureMode = intent
            }
        }
        if let intent = intendedWhiteBalanceMode {
            if updated.whiteBalanceMode == intent {
                intendedWhiteBalanceMode = nil
            } else {
                updated.whiteBalanceMode = intent
            }
        }

        // Pin ISO / shutter / WB Kelvin to the user-set values while the
        // AVFoundation commit is in flight. Each axis clears its override
        // independently the moment the device reports a value close enough to
        // the intent (within 0.5 % for floating-point comparison), so the
        // state snaps to the real device reading the instant AVF lands —
        // without this convergence check the override would leak past the
        // commit and the user couldn't drag the slider to a slightly different
        // value (e.g. 800 → 801) because the override would keep painting 800.
        if let intent = intendedISO {
            if abs(updated.iso - intent) / max(intent, 1) < 0.005 {
                intendedISO = nil
            } else {
                updated.iso = intent
            }
        }
        if let intent = intendedExposureDurationSeconds {
            if let actual = updated.exposureDurationSeconds,
               actual > 0, abs(actual - intent) / intent < 0.05 {
                intendedExposureDurationSeconds = nil
            } else {
                updated.exposureDurationSeconds = intent
            }
        }
        if let intent = intendedWhiteBalanceTemperature {
            if abs(updated.whiteBalanceTemperature - intent) / max(intent, 1) < 0.01 {
                intendedWhiteBalanceTemperature = nil
            } else {
                updated.whiteBalanceTemperature = intent
            }
        }

        // Snapshot the auto-exposure baseline whenever the device is settled in
        // a continuous / auto exposure mode AND the user isn't actively driving
        // any intent. The baseline is the reference point for `setISO` and
        // `setShutterSpeed`'s reciprocity math (Tv/Av-priority): when the user
        // drags one axis, the other is recomputed from this baseline so the
        // overall light value the auto path was metering is preserved. The
        // intent-null guard is important — without it, an in-flight custom
        // commit's transient `.continuousAuto` reads would update the baseline
        // mid-drag and the next axis change would compensate against the
        // wrong reference.
        let isAutoExposure = updated.exposureMode == .continuousAutoExposure
            || updated.exposureMode == .autoExpose
        let noActiveIntent = intendedExposureMode == nil
            && intendedISO == nil
            && intendedExposureDurationSeconds == nil
        if isAutoExposure, noActiveIntent,
           updated.iso > 0,
           let durationSeconds = updated.exposureDurationSeconds,
           durationSeconds > 0 {
            autoExposureBaselineISO = updated.iso
            autoExposureBaselineDurationSeconds = durationSeconds
        }

        state = updated
        stateStreams.yield(state)
    }

    private func refreshDevice() async {
        let snapshot = await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return PRMCameraDevice?.none }
            return PRMCameraDevice(snapshotting: device)
        }
        device = snapshot
    }

    /// Hops to ``PRMCameraActor`` and runs `work` against the current video device.
    /// No-ops when the session has no video device (pre-configure, between switchCamera
    /// failures). Callers use `try?` inside `work` for transient AVFoundation errors
    /// (device lock contention, mode unsupported on the current device) where retrying
    /// is unlikely to help and the operation is best-effort — typical for slider-driven
    /// continuous setters that fire many times per second. Use ``runOnDeviceThrowing(_:)``
    /// instead when a single failure is significant (e.g. virtual-device rejection of
    /// manual exposure) and the camera should surface it on the error stream.
    private func runOnDevice(_ work: @escaping @Sendable (AVCaptureDevice) -> Void) async {
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return }
            work(device)
        }
    }

    /// Throwing variant of ``runOnDevice(_:)``. Returns the thrown error (or `nil` on
    /// success / no device) so callers can decide whether to surface it via
    /// ``emitError(_:)`` or swallow. Kept as an `Error?` return rather than re-throwing
    /// so the public camera-facing setters stay non-throwing — surfacing failures
    /// through the error stream keeps the API symmetrical with AVFoundation's own
    /// notification-based error reporting.
    private func runOnDeviceThrowing(_ work: @escaping @Sendable (AVCaptureDevice) throws -> Void) async -> Error? {
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return Error?.none }
            do {
                try work(device)
                return nil
            } catch {
                return error
            }
        }
    }

    /// Drops every user-driven intent override and the auto-exposure baseline.
    /// Called whenever the underlying device/configuration changes out from under
    /// the intent values (configure, switchCamera, switchDevice) — the new device
    /// starts in `.continuousAuto` for both exposure and WB, and a stale intent
    /// from before the change would keep `refreshState` painting the old custom
    /// values onto the new device's snapshot.
    private func clearIntendedState() {
        intendedExposureMode = nil
        intendedWhiteBalanceMode = nil
        intendedISO = nil
        intendedExposureDurationSeconds = nil
        intendedWhiteBalanceTemperature = nil
        autoExposureBaselineISO = nil
        autoExposureBaselineDurationSeconds = nil
    }

    /// Yields a session error to every active subscriber on ``errorStream()``.
    /// Used to surface non-throwing device-helper failures (e.g. the virtual-device
    /// rejection from ``AVCaptureDevice/prm_setCustomExposure(duration:iso:completion:)``)
    /// so consumers see a signal instead of a silently dropped command.
    private func emitError(_ error: PRMSessionError) {
        errorStreams.yield(error)
    }
}
