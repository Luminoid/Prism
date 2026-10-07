@preconcurrency import AVFoundation
import os

// MARK: - Device-level observation

//
// The session-level observers live on `PRMCamera` (`PRMCamera+Observers.swift`). These are
// the device-level ones: properties AVFoundation changes on its own (smudge status, system
// pressure, tracking, aspect ratio, Smart Framing). They're owned by the session because
// only the session knows every path that replaces `videoDevice` (configure, input swap,
// full reconfigure); `videoDevice`'s `didSet` calls `installDeviceObservers()`.
//
// Every change handler is `@Sendable` and touches nothing but the Sendable registries, so
// the closures carry no actor isolation: KVO fires them on arbitrary queues.

extension PRMCameraSession {
    /// Re-binds device KVO to the current `videoDevice`. Called from `videoDevice`'s
    /// `didSet` whenever the device identity changes.
    func installDeviceObservers() {
        for observation in deviceObservations {
            observation.invalidate()
        }
        deviceObservations.removeAll()
        let events = deviceEvents
        let latestFraming = latestFramingRecommendation
        guard let device = videoDevice else {
            latestFraming.withLock { $0 = nil }
            framingRecommendations.yield(nil)
            events.yield(())
            return
        }

        var observations: [NSKeyValueObservation] = [
            device.observe(\.systemPressureState, options: [.old, .new]) { @Sendable _, change in
                Self.logSystemPressureChange(from: change.oldValue, to: change.newValue)
                events.yield(())
            },
            device.observe(\.lensAperture) { @Sendable _, _ in events.yield(()) },
        ]
        if #available(iOS 26.0, *) {
            observations.append(device.observe(\.cameraLensSmudgeDetectionStatus) { @Sendable _, _ in events.yield(()) })
            observations.append(device.observe(\.cinematicVideoCaptureSceneMonitoringStatuses) { @Sendable _, _ in events.yield(()) })
            observations.append(device.observe(\.dynamicAspectRatio) { @Sendable _, _ in events.yield(()) })
            if let monitor = device.smartFramingMonitor {
                let recommendations = framingRecommendations
                observations.append(
                    monitor.observe(\.recommendedFraming, options: [.initial, .new]) { @Sendable monitor, _ in
                        let framing = monitor.recommendedFraming.flatMap(PRMFraming.init)
                        latestFraming.withLock { $0 = framing }
                        recommendations.yield(framing)
                    }
                )
            } else {
                latestFraming.withLock { $0 = nil }
                framingRecommendations.yield(nil)
            }
        }
        if #available(iOS 27.0, *) {
            observations.append(device.observe(\.activeExposureSignals) { @Sendable _, _ in events.yield(()) })
            observations.append(device.observe(\.isContinuousAutoFocusTrackingSubjectAcquired) { @Sendable _, _ in events.yield(()) })
        }
        deviceObservations = observations
        // The KVO above reports changes only; say so when the new device is already under pressure.
        if PRMSystemPressure(device.systemPressureState).level > .nominal {
            Self.logSystemPressureChange(from: nil, to: device.systemPressureState)
        }
        events.yield(())
    }

    /// Logs a system-pressure level change: notice while nominal or fair, warning from
    /// serious up (AVFoundation throttles frame rate there and stops capture at shutdown).
    /// Factor-only changes at the same level aren't logged.
    nonisolated static func logSystemPressureChange(
        from old: AVCaptureDevice.SystemPressureState?,
        to new: AVCaptureDevice.SystemPressureState?
    ) {
        guard let new else { return }
        let pressure = PRMSystemPressure(new)
        if let old, PRMSystemPressure(old).level == pressure.level { return }
        let level: PRMLogLevel = pressure.level >= .serious ? .warning : .notice
        PRMLog.log(level, .session, "System pressure changed to \(pressure.logDescription)")
    }
}
