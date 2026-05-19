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
        }
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
            newState.exposureMode = device.exposureMode
            newState.exposureBias = device.exposureTargetBias
            newState.iso = device.iso
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

// MARK: - PRMCameraActor helper

public extension PRMCameraActor {
    /// Runs an isolated closure on the actor and returns its result.
    static func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await body()
    }

    /// Instance-method shim so callers can write `await PRMCameraActor.shared.run { ... }`.
    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await body()
    }
}
