@preconcurrency import AVFoundation

// MARK: - iOS 26 / 27 manual controls

//
// Variable aperture and priority modes, exposure signals and the lens lock (iOS 27), plus
// rectangle-of-interest focus and exposure (iOS 26). Split from `PRMCamera.swift` to keep
// that file on the long-standing controls. All setters are non-throwing: failures go to
// ``PRMCamera/errorStream()``, like the existing manual-exposure setters.

public extension PRMCamera {
    // MARK: Priority modes (iOS 27)

    /// The axes the user locked in an iOS 27 priority mode (e.g. `.shutter` in shutter
    /// priority). Empty in the auto modes and in full manual.
    ///
    /// Capture code can use it to request `.speed` quality prioritization, which the SDK
    /// requires for stills to honor locked values in low light.
    var exposurePriorityAxes: PRMExposureAxes {
        let isCustom = state.exposureMode == .custom || intendedExposureMode == .custom
        let autoAxes = intendedAutoExposureAxes ?? state.autoExposureAxes
        guard isCustom, !autoAxes.isEmpty, autoAxes != .all else { return [] }
        return PRMExposureAxes.all.subtracting(autoAxes)
    }

    /// Sets a custom exposure with each axis locked to a value, locked where it is, or left
    /// to auto exposure (iOS 27). See `AVCaptureDevice.prm_setExposure(aperture:shutterSeconds:iso:completion:)`.
    ///
    /// Locked values are pinned in ``state`` until the device commits (which can take a
    /// few seconds for long exposures); auto axes follow the device. Unsupported
    /// combinations, older systems and virtual multi-camera devices emit an error on
    /// ``errorStream()`` and leave the exposure unchanged.
    ///
    /// Unlike ``setISO(_:baseline:)`` / ``setShutterSpeed(seconds:baseline:)``, which lock
    /// both axes at reciprocal values, an `.auto` axis keeps metering as the scene changes.
    func setExposure(
        aperture: PRMExposureValue<Float> = .current,
        shutterSeconds: PRMExposureValue<Double> = .current,
        iso: PRMExposureValue<Float> = .current
    ) async {
        PRMLog.debug(.session, "PRMCamera.setExposure(aperture=\(aperture), shutter=\(shutterSeconds), iso=\(iso))")
        let previous = (
            mode: intendedExposureMode,
            axes: intendedAutoExposureAxes,
            aperture: intendedLensAperture,
            iso: intendedISO,
            duration: intendedExposureDurationSeconds
        )
        intendedExposureMode = .custom
        intendedAutoExposureAxes = PRMExposureAxes(
            apertureAuto: aperture.isAuto,
            shutterAuto: shutterSeconds.isAuto,
            isoAuto: iso.isAuto
        )
        // Pin what the device will actually be set to (it clamps), so the intents can
        // converge with the device's readings.
        intendedLensAperture = Self.pinnedIntent(aperture.clamped(to: device?.apertureRange), current: intendedLensAperture)
        intendedISO = Self.pinnedIntent(iso.clamped(to: device?.isoRange), current: intendedISO)
        intendedExposureDurationSeconds = Self.pinnedIntent(shutterSeconds.clamped(to: device?.shutterRange), current: intendedExposureDurationSeconds)
            .flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        let thrown = await runOnDeviceThrowing { device in
            try device.prm_setExposure(aperture: aperture, shutterSeconds: shutterSeconds, iso: iso) { _ in
                NotificationCenter.default.post(name: Self.deviceCommitNotification, object: nil)
            }
        }
        if let thrown {
            intendedExposureMode = previous.mode
            intendedAutoExposureAxes = previous.axes
            intendedLensAperture = previous.aperture
            intendedISO = previous.iso
            intendedExposureDurationSeconds = previous.duration
            // Slider-driven (priority modes, aperture): logged once per error until a call succeeds.
            emitAnyError(thrown, throttledBy: "setExposure")
        } else {
            clearThrottledLogs(for: "setExposure")
        }
        await refreshState()
    }

    /// Shutter priority (iOS 27): locks the exposure duration; aperture and ISO keep
    /// metering.
    func setShutterPriority(seconds: Double) async {
        await setExposure(aperture: .auto, shutterSeconds: .fixed(seconds), iso: .auto)
    }

    /// ISO priority (iOS 27): locks ISO; aperture and shutter keep metering.
    func setISOPriority(_ iso: Float) async {
        await setExposure(aperture: .auto, shutterSeconds: .auto, iso: .fixed(iso))
    }

    /// Aperture priority (iOS 27, variable-aperture cameras): locks the 𝑓-number; shutter
    /// and ISO keep metering.
    func setAperturePriority(_ fNumber: Float) async {
        await setExposure(aperture: .fixed(fNumber), shutterSeconds: .auto, iso: .auto)
    }

    /// Limits how fast auto exposure moves the aperture (iOS 27). See
    /// `AVCaptureDevice.prm_setAutoApertureRateLimit(_:)`.
    func setAutoApertureRateLimit(_ ratio: Float) async {
        let thrown = await runOnDeviceThrowing { try $0.prm_setAutoApertureRateLimit(ratio) }
        if let thrown { emitAnyError(thrown) }
    }

    // MARK: Exposure signals (iOS 27)

    /// Chooses which scene signals auto exposure may weigh (iOS 27); `nil` restores the
    /// system's choice. Check ``PRMCameraDevice/supportedExposureSignals`` first.
    func setExposureSignals(_ signals: Set<PRMExposureSignal>?) async {
        let thrown = await runOnDeviceThrowing { try $0.prm_setExposureSignals(signals) }
        if let thrown { emitAnyError(thrown) }
        await refreshState()
    }

    // MARK: Lens lock (iOS 27)

    /// Pins a virtual camera to one of its lenses (iOS 27), so low light or a close subject
    /// can't make AVFoundation fall back to another one. Pass `nil` to unlock. Zoom is
    /// clamped into the locked lens's range. ``PRMCameraState/isPrimaryConstituentLocked``
    /// and ``PRMCameraState/activePrimaryDeviceType`` report the result.
    func lockLens(_ type: AVCaptureDevice.DeviceType?) async {
        let thrown = await runOnDeviceThrowing { try $0.prm_lockPrimaryConstituent(to: type) }
        if let thrown { emitAnyError(thrown) }
        await refreshDevice()
        await refreshState()
    }

    // MARK: Rect of interest (iOS 26)

    /// Focuses and meters on a rectangle (device space, `0...1`) instead of a point
    /// (iOS 26). Falls back to the rect's center on older systems or devices without rect
    /// support. While Cinematic Video is enabled this only sets exposure and asks Cinematic
    /// Video to track the subject at the rect's center.
    func setFocusAndExposure(
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        in rect: CGRect,
        monitorSubjectAreaChange: Bool = false
    ) async {
        noteExposureModeIntent(exposureMode)
        let monitor = await monitorsSubjectArea(requested: monitorSubjectAreaChange)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let thrown = await runOnDeviceCheckingCinematic { device, cinematic in
            if cinematic {
                try Self.applyCinematicTapFocus(on: device, exposureMode: exposureMode, at: center)
            } else {
                PRMLog.bestEffort(.session, "setFocusAndExposure(in:)") {
                    try device.prm_setFocusAndExposure(
                        focusMode: focusMode,
                        exposureMode: exposureMode,
                        in: rect,
                        monitorSubjectAreaChange: monitor
                    )
                }
            }
        }
        if let thrown { emitAnyError(thrown) }
        await refreshState()
    }

    /// The focus rectangle AVFoundation uses by default around a point (iOS 26), for
    /// sizing a focus indicator. `nil` when unsupported.
    func defaultFocusRect(for devicePoint: CGPoint) async -> CGRect? {
        await PRMCameraActor.shared.run { [session] in
            await session.videoDevice?.prm_defaultFocusRect(for: devicePoint)
        }
    }
}

extension PRMCamera {
    /// The intent to pin for one axis: the value for `.fixed`, nothing for `.auto` (the
    /// device drives it), and the existing intent for `.current`.
    static func pinnedIntent<Value>(_ value: PRMExposureValue<Value>, current: Value?) -> Value? {
        switch value {
        case let .fixed(fixed): fixed
        case .auto: nil
        case .current: current
        }
    }

    /// Records an exposure mode chosen by a tap-to-focus. Leaving custom exposure drops the
    /// pinned manual values and the iOS 27 priority intents, as ``setExposureMode(_:)`` does.
    func noteExposureModeIntent(_ mode: AVCaptureDevice.ExposureMode) {
        intendedExposureMode = mode
        if mode != .custom {
            intendedISO = nil
            intendedExposureDurationSeconds = nil
            intendedAutoExposureAxes = nil
            intendedLensAperture = nil
        }
    }

    /// Runs `work` on the camera actor with the current device and whether Cinematic Video
    /// is enabled, read in the same actor turn as the mutation (see
    /// ``PRMCameraSession/withVideoDevice(_:)``). Returns the thrown error, if any.
    func runOnDeviceCheckingCinematic(_ work: @escaping @Sendable (AVCaptureDevice, Bool) throws -> Void) async -> (any Error)? {
        do {
            try await session.refuseDuringExclusiveCapture("Changing camera settings")
            try await session.withVideoDevice(work)
            return nil
        } catch {
            return error
        }
    }

    /// Subject-area monitoring for a tap-to-focus: off while iOS 27 subject tracking is
    /// on, since its re-centering would retarget the tracker.
    func monitorsSubjectArea(requested: Bool) async -> Bool {
        guard requested else { return false }
        return await !session.wantsContinuousAutoFocusTracking
    }

    /// Routes any error to ``errorStream()``, wrapping non-Prism errors (the original is
    /// logged). `throttledBy` as in ``emitError(_:cause:throttledBy:file:line:)``.
    func emitAnyError(_ error: any Error, throttledBy setter: String? = nil, file: String = #fileID, line: Int = #line) {
        if let sessionError = error as? PRMSessionError {
            emitError(sessionError, throttledBy: setter, file: file, line: line)
        } else {
            emitError(.unsupportedConfiguration(error.localizedDescription), cause: error, throttledBy: setter, file: file, line: line)
        }
    }
}
