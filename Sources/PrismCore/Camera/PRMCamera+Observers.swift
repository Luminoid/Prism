@preconcurrency import AVFoundation
import Foundation

// MARK: - Observer installation

//
// Split out of `PRMCamera.swift` so the facade's body stays focused on device-mutation
// public methods (start/stop, switch, manual exposure, WB lock, etc.). This file owns
// the KVO + NotificationCenter wiring: session.isRunning, device-commit notifications
// from `setExposureModeCustom` / `setWhiteBalanceModeLocked`, AVCaptureSession runtime
// errors, and interruption begin/end. The same wiring pattern repeats four times so
// keeping it adjacent here makes the wiring easier to audit.
//
// All closures hop to MainActor via `Task { @MainActor in ... }` because the underlying
// KVO and notification block delivery isn't actor-isolated. The Tasks are fire-and-
// forget: each body is a single short MainActor dispatch that yields a stream value,
// and `[weak self]` ensures the Task no-ops if the camera has deinited. Observers are
// invalidated in PRMCamera.deinit (and in this method's re-entrant teardown at the
// top), so no new Tasks are spawned after teardown.

extension PRMCamera {
    /// (Re)installs the four observers. Re-entrant: a follow-up `configure(_:)` call
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
            Task { @MainActor [weak self] in
                guard let self, let avError else { return }
                errorStreams.yield(.runtime(avError))
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    state.isInterrupted = false
                    interruptionStreams.yield(false)
                    stateStreams.yield(state)
                }
            }
            notificationObservers.append(endedObserver)
        #endif
    }
}
