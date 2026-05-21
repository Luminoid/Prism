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

    // MARK: - Init

    public init(session: PRMCameraSession? = nil) {
        self.session = session ?? PRMCameraSession.makeDefaultMainActor()
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
        await runOnDevice { try? $0.prm_setExposureMode(mode) }
        await refreshState()
    }

    public func setCustomExposure(duration: CMTime, iso: Float) async {
        await runOnDevice { try? $0.prm_setCustomExposure(duration: duration, iso: iso) }
        await refreshState()
    }

    public func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) async {
        await runOnDevice { try? $0.prm_setWhiteBalanceMode(mode) }
        await refreshState()
    }

    public func lockWhiteBalance(_ values: AVCaptureDevice.PRMTemperatureAndTint) async {
        await runOnDevice { try? $0.prm_lockWhiteBalance(values) }
        await refreshState()
    }

    public func lockWhiteBalance(preset: AVCaptureDevice.PRMWhiteBalancePreset) async {
        await runOnDevice { try? $0.prm_lockWhiteBalance(preset: preset) }
        await refreshState()
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

    /// Sets manual ISO at the current shutter speed.
    public func setISO(_ iso: Float) async {
        await runOnDevice { try? $0.prm_setISO(iso) }
        await refreshState()
    }

    /// Sets manual shutter speed (in seconds) at the current ISO.
    public func setShutterSpeed(seconds: Double) async {
        await runOnDevice { try? $0.prm_setShutterSpeed(seconds: seconds) }
        await refreshState()
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
