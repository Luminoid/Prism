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
    fileprivate nonisolated static let deviceCommitNotification = Notification.Name("com.luminoid.Prism.deviceCommit")

    /// Underlying session — escape hatch for advanced AVFoundation work.
    public let session: PRMCameraSession

    /// Snapshot of the active device's capabilities. `nil` before ``configure(_:)`` succeeds.
    public private(set) var device: PRMCameraDevice?

    /// Most recent observed state. Updated by ``refreshState()`` and by mutation methods.
    public private(set) var state = PRMCameraState()

    private var stateContinuations: [UUID: AsyncStream<PRMCameraState>.Continuation] = [:]
    private var errorContinuations: [UUID: AsyncStream<PRMSessionError>.Continuation] = [:]
    private var interruptionContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    private var keyValueObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [any NSObjectProtocol] = []

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
        intendedISO = nil
        intendedExposureDurationSeconds = nil
        intendedWhiteBalanceTemperature = nil
        autoExposureBaselineISO = nil
        autoExposureBaselineDurationSeconds = nil
    }

    deinit {
        for obs in keyValueObservations {
            obs.invalidate()
        }
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        for continuation in errorContinuations.values {
            continuation.finish()
        }
        for continuation in interruptionContinuations.values {
            continuation.finish()
        }
    }

    // MARK: - Lifecycle

    /// Configures the session and refreshes ``device`` + ``state``.
    public func configure(_ configuration: PRMCameraConfiguration) async throws {
        // Reconfigure clears any per-session manual-exposure / WB intents — the
        // new session starts in `.continuousAuto` for both axes, and we don't
        // want a stale intent from before configure to keep overriding the read.
        intendedExposureMode = nil
        intendedWhiteBalanceMode = nil
        intendedISO = nil
        intendedExposureDurationSeconds = nil
        intendedWhiteBalanceTemperature = nil
        autoExposureBaselineISO = nil
        autoExposureBaselineDurationSeconds = nil
        try await session.configure(configuration)
        await refreshDevice()
        await refreshState()
        await installObservers()
    }

    /// Starts the session. Idempotent.
    public func start() async {
        await session.start()
        await refreshState()
    }

    /// Stops the session. Idempotent.
    public func stop() async {
        await session.stop()
        await refreshState()
    }

    /// Switches the camera position and refreshes ``device``.
    public func switchCamera(to position: AVCaptureDevice.Position) async throws {
        // The new physical device starts in `.continuousAuto` — drop intents so
        // the override doesn't keep painting the old custom state on the new lens.
        intendedExposureMode = nil
        intendedWhiteBalanceMode = nil
        intendedISO = nil
        intendedExposureDurationSeconds = nil
        intendedWhiteBalanceTemperature = nil
        autoExposureBaselineISO = nil
        autoExposureBaselineDurationSeconds = nil
        _ = try await session.switchCamera(to: position)
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
        intendedExposureMode = nil
        intendedWhiteBalanceMode = nil
        intendedISO = nil
        intendedExposureDurationSeconds = nil
        intendedWhiteBalanceTemperature = nil
        autoExposureBaselineISO = nil
        autoExposureBaselineDurationSeconds = nil
        _ = try await session.switchDevice(type: type, position: position)
        await refreshDevice()
        await refreshState()
    }

    /// Toggle the movie file output between video-recording mode (attached, Live Photo
    /// unavailable) and Live-Photo-capable mode (detached). See
    /// ``PRMCameraSession/setMovieFileOutputAttached(_:)`` for the rationale.
    public func setMovieFileOutputAttached(_ attached: Bool) async throws {
        try await session.setMovieFileOutputAttached(attached)
    }

    /// Runtime toggle for Live Photo capability on the photo output. See
    /// ``PRMCameraSession/setLivePhotoCaptureEnabled(_:)`` — flip this off before
    /// entering manual exposure (custom ISO / shutter / WB lock) and back on when the
    /// user returns to auto exposure with Live Photo capture intended.
    public func setLivePhotoCaptureEnabled(_ enabled: Bool) async {
        await session.setLivePhotoCaptureEnabled(enabled)
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
        await runOnDevice { device in
            try? device.prm_setCustomExposure(duration: duration, iso: iso) { _ in
                NotificationCenter.default.post(name: Self.deviceCommitNotification, object: nil)
            }
        }
        await refreshState()
    }

    public func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) async {
        intendedWhiteBalanceMode = mode
        if mode != .locked {
            intendedWhiteBalanceTemperature = nil
        }
        await runOnDevice { try? $0.prm_setWhiteBalanceMode(mode) }
        await refreshState()
    }

    public func lockWhiteBalance(_ values: AVCaptureDevice.PRMTemperatureAndTint) async {
        intendedWhiteBalanceMode = .locked
        intendedWhiteBalanceTemperature = values.temperature
        // Same async-completion handling as `setCustomExposure` — see that doc.
        // Refresh-via-notification keeps continuous Kelvin slider drags fluent
        // while still landing the final "locked" Kelvin after the completion
        // fires. The `intendedWhiteBalanceTemperature` override above keeps
        // `state.whiteBalanceTemperature` pinned to the user's value during
        // the commit window, so the slider doesn't snap back to the old
        // auto-driven Kelvin after the user releases.
        await runOnDevice { device in
            try? device.prm_lockWhiteBalance(values) { _ in
                NotificationCenter.default.post(name: Self.deviceCommitNotification, object: nil)
            }
        }
        await refreshState()
    }

    public func lockWhiteBalance(preset: AVCaptureDevice.PRMWhiteBalancePreset) async {
        await lockWhiteBalance(
            AVCaptureDevice.PRMTemperatureAndTint(temperature: preset.temperature, tint: 0)
        )
    }

    public func setFrameRate(_ fps: Float64, allowFormatChange: Bool = true) async {
        await runOnDevice { _ = try? $0.prm_setFrameRate(fps, allowFormatChange: allowFormatChange) }
        await refreshState()
    }

    public func resetFrameRate() async {
        await runOnDevice { try? $0.prm_resetFrameRate() }
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
    public func setISO(_ iso: Float) async {
        guard let baselineISO = autoExposureBaselineISO,
              let baselineDur = autoExposureBaselineDurationSeconds,
              baselineISO > 0, iso > 0
        else {
            await setCustomExposure(duration: AVCaptureDevice.currentExposureDuration, iso: iso)
            return
        }
        let targetLV = Double(baselineISO) * baselineDur
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
    public func setShutterSpeed(seconds: Double) async {
        guard let baselineISO = autoExposureBaselineISO,
              let baselineDur = autoExposureBaselineDurationSeconds,
              baselineDur > 0, seconds > 0
        else {
            let durationCM = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
            await setCustomExposure(duration: durationCM, iso: AVCaptureDevice.currentISO)
            return
        }
        let targetLV = Double(baselineISO) * baselineDur
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

    // Cleanup tasks in the `onTermination` blocks below are deliberately fire-and-forget:
    // they run a single MainActor hop to remove the continuation entry and exit. Storing
    // these handles would only complicate cancellation without changing behavior — the work
    // is short-lived, uses `[weak self]`, and is harmless if `self` has deinited (the
    // dictionary is gone too).

    /// Async stream of state snapshots.
    ///
    /// Yields the current ``state`` immediately on subscribe, then a new value on every
    /// mutation. This is the only stream that yields an initial value — error and
    /// interruption streams only emit on actual events.
    public func stateStream() -> AsyncStream<PRMCameraState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Async stream of runtime errors emitted by the session.
    ///
    /// Does **not** yield an initial value — there is no "current error" concept. Errors
    /// already in flight before you subscribe are lost; subscribe before
    /// ``configure(_:)``/``start()`` to catch boot-time failures.
    public func errorStream() -> AsyncStream<PRMSessionError> {
        AsyncStream { continuation in
            let id = UUID()
            errorContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.errorContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Async stream of interruption events. `true` = interrupted, `false` = resumed.
    ///
    /// Does **not** yield an initial value — to read the current interruption status,
    /// check ``state``.`isInterrupted` directly.
    public func interruptionStream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            interruptionContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.interruptionContinuations.removeValue(forKey: id)
                }
            }
        }
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
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func refreshDevice() async {
        let snapshot = await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return PRMCameraDevice?.none }
            return PRMCameraDevice(snapshotting: device)
        }
        device = snapshot
    }

    private func runOnDevice(_ work: @escaping @Sendable (AVCaptureDevice) -> Void) async {
        await PRMCameraActor.shared.run { [session] in
            guard let device = await session.videoDevice else { return }
            work(device)
        }
    }

    // MARK: - Observers

    private func installObservers() async {
        // The KVO/notification closures below hop to MainActor via `Task { @MainActor in ... }`.
        // These tasks are fire-and-forget by design: each one's body is a single short MainActor
        // dispatch that yields a stream value. Storing handles would only add bookkeeping with
        // no observable behavior change — `[weak self]` ensures the task no-ops if the camera
        // has deinited, and the underlying observers are invalidated in `deinit` so no new tasks
        // are spawned after teardown.
        //
        // Re-entrant: a follow-up `configure(_:)` call re-runs this method. Drop the
        // previous observers first so we don't end up with duplicates yielding the same
        // state twice per change (and re-adding them on every Apply tap in the
        // ConfigurationLab example).
        for obs in keyValueObservations {
            obs.invalidate()
        }
        keyValueObservations.removeAll()
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        let underlyingSession = session.session

        let runningObservation = underlyingSession.observe(\.isRunning, options: .new) { [weak self] _, change in
            guard let isRunning = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                state.isRunning = isRunning
                for continuation in stateContinuations.values {
                    continuation.yield(state)
                }
            }
        }
        keyValueObservations.append(runningObservation)

        // Route `setExposureModeCustom` / `setWhiteBalanceModeLocked` completion-handler
        // posts to `refreshState`. The completion handler can't capture `self` (it
        // crosses the @Sendable boundary from a non-Sendable @MainActor class), so the
        // device-completion paths post to NotificationCenter and we observe here.
        let commitObserver = NotificationCenter.default.addObserver(
            forName: Self.deviceCommitNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshState()
            }
        }
        notificationObservers.append(commitObserver)

        let runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: underlyingSession,
            queue: .main
        ) { [weak self] notification in
            let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Task { @MainActor [weak self] in
                guard let self, let avError else { return }
                for continuation in errorContinuations.values {
                    continuation.yield(.runtime(avError))
                }
            }
        }
        notificationObservers.append(runtimeErrorObserver)

        #if !os(macOS)
            let interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: underlyingSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    state.isInterrupted = true
                    for continuation in interruptionContinuations.values {
                        continuation.yield(true)
                    }
                    for continuation in stateContinuations.values {
                        continuation.yield(state)
                    }
                }
            }
            notificationObservers.append(interruptionObserver)

            let endedObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: underlyingSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    state.isInterrupted = false
                    for continuation in interruptionContinuations.values {
                        continuation.yield(false)
                    }
                    for continuation in stateContinuations.values {
                        continuation.yield(state)
                    }
                }
            }
            notificationObservers.append(endedObserver)
        #endif
    }
}
