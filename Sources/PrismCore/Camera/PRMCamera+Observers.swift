@preconcurrency import AVFoundation
import Foundation

// MARK: - Observer installation

//
// Split out of `PRMCamera.swift` so the facade's body stays focused on device-mutation
// public methods (start/stop, switch, manual exposure, WB lock, etc.). This file owns
// the KVO + NotificationCenter wiring: session.isRunning, device-commit notifications
// from `setExposureModeCustom` / `setWhiteBalanceModeLocked`, AVCaptureSession runtime
// errors, interruption begin/end, and the process thermal state. The same wiring pattern
// repeats for each so keeping it adjacent here makes the wiring easier to audit. Each
// observer also writes the event to the unified log (subsystem `dev.luminoid.prism`,
// category `Session`), so field logs show what the streams reported.
//
// All closures hop to MainActor via `Task { @MainActor in ... }` because the underlying
// KVO and notification block delivery isn't actor-isolated. The Tasks are fire-and-
// forget: each body is a single short MainActor dispatch that yields a stream value,
// and `[weak self]` ensures the Task no-ops if the camera has deinited. Observers are
// invalidated in PRMCamera.deinit (and in this method's re-entrant teardown at the
// top), so no new Tasks are spawned after teardown.

extension PRMCamera {
    /// (Re)installs the observers. Re-entrant: a follow-up `configure(_:)` call
    /// re-runs this method. Drops the previous observers first so we don't end up with
    /// duplicates yielding the same state twice per change (and re-adding them on
    /// every Apply tap in the ConfigurationLab example).
    func installObservers() async {
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
            PRMLog.notice(.session, "AVCaptureSession isRunning changed to \(isRunning)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                state.isRunning = isRunning
                stateStreams.yield(state)
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
            guard let avError else {
                // Nothing to put on the stream, but the session still reported a failure.
                let underlying = notification.userInfo?[AVCaptureSessionErrorKey] as? any Error
                PRMLog.error(.session, "AVCaptureSession runtime error notification without an AVError", error: underlying)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // `emitError` logs the AVError domain and code.
                emitError(.runtime(avError))
                // AVFoundation stopped the session; restart it if the app still wants it
                // running, or the preview stays black until a reconfigure.
                if avError.code == .mediaServicesWereReset {
                    await session.restartAfterMediaServicesReset()
                    await refreshState()
                }
            }
        }
        notificationObservers.append(runtimeErrorObserver)

        #if !os(macOS)
            let interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: underlyingSession,
                queue: .main
            ) { [weak self] notification in
                // iOS 26 adds `.sensitiveContentMitigationActivated` to the reasons.
                let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                PRMLog.notice(.session, "AVCaptureSession interrupted: \(reason?.prm_logName ?? "no reason given")")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    state.isInterrupted = true
                    state.interruptionReason = reason
                    interruptionStreams.yield(true)
                    stateStreams.yield(state)
                }
            }
            notificationObservers.append(interruptionObserver)

            let endedObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: underlyingSession,
                queue: .main
            ) { [weak self] _ in
                PRMLog.notice(.session, "AVCaptureSession interruption ended")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    state.isInterrupted = false
                    state.interruptionReason = nil
                    interruptionStreams.yield(false)
                    stateStreams.yield(state)
                }
            }
            notificationObservers.append(endedObserver)
        #endif

        // Heat throttles capture long before `systemPressureState` reaches `.shutdown`, so
        // field logs need the process thermal state next to the session's own events.
        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Self.logThermalState(ProcessInfo.processInfo.thermalState)
        }
        notificationObservers.append(thermalObserver)
    }

    /// Writes a thermal-state change: notice while it's nominal or fair, warning from
    /// serious up (the system starts throttling the camera).
    nonisolated static func logThermalState(_ thermalState: ProcessInfo.ThermalState) {
        let level: PRMLogLevel = thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .warning : .notice
        PRMLog.log(level, .session, "Thermal state changed to \(thermalState.prm_logName)")
    }
}
