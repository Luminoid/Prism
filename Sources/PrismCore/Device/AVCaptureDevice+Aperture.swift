import AVFoundation
import CoreMedia

// iOS 27 exposure triangle: variable lens aperture, "priority" modes that lock some axes
// and let auto exposure drive the rest, and the exposure signals that steer auto exposure.

public extension AVCaptureDevice {
    // MARK: - Aperture capability

    /// Supported lens 𝑓-number range for the active format, or `nil` when the aperture is
    /// fixed or the OS is older than iOS 27.
    var prm_lensApertureRange: ClosedRange<Float>? {
        guard #available(iOS 27.0, *) else { return nil }
        let format = activeFormat
        guard format.minLensAperture > 0, format.maxLensAperture > format.minLensAperture else { return nil }
        return format.minLensAperture ... format.maxLensAperture
    }

    /// The exposure axes the auto-exposure system is driving right now. Per-axis on iOS 27
    /// (`automaticallyAdjustsLensAperture` / `…ExposureDuration` / `…ISO`); derived from
    /// `exposureMode` before that.
    var prm_autoExposureAxes: PRMExposureAxes {
        guard #available(iOS 27.0, *) else { return PRMExposureAxes(exposureMode: exposureMode) }
        return PRMExposureAxes(
            apertureAuto: automaticallyAdjustsLensAperture,
            shutterAuto: automaticallyAdjustsExposureDuration,
            isoAuto: automaticallyAdjustsISO
        )
    }

    // MARK: - Priority modes

    /// Whether the active format accepts this combination of locked and auto axes. Always
    /// `false` before iOS 27. Explicit values are only range-checked; `.current` and `.auto`
    /// test the lock/auto combination itself.
    func prm_supportsExposure(
        aperture: PRMExposureValue<Float> = .current,
        shutterSeconds: PRMExposureValue<Double> = .current,
        iso: PRMExposureValue<Float> = .current
    ) -> Bool {
        guard #available(iOS 27.0, *) else { return false }
        let values = prm_resolvedExposureValues(aperture: aperture, shutterSeconds: shutterSeconds, iso: iso)
        return activeFormat.supportsExposureModeCustom(
            lensAperture: values.aperture,
            duration: values.duration,
            iso: values.iso
        )
    }

    /// Sets a custom exposure where each axis is locked to a value, locked where it is, or
    /// left to auto exposure (iOS 27 `setExposureModeCustom(lensAperture:duration:iso:)`).
    ///
    /// Shutter priority is `shutterSeconds: .fixed(1/250)` with aperture and ISO `.auto`;
    /// aperture priority locks the aperture, and so on. Explicit values are clamped to the
    /// active format's ranges.
    ///
    /// When every axis is locked (none `.auto`), this behaves like
    /// ``prm_setCustomExposure(duration:iso:completion:)``: the face-driven AE and auto-HDR
    /// systems that fight manual values are switched off. With any `.auto` axis they stay
    /// on, because auto exposure is still metering.
    ///
    /// For still captures to honor locked values, capture with `.speed` quality
    /// prioritization: the default `.balanced` may override ISO and duration in low light.
    ///
    /// - Throws: ``PRMSessionError/exposureCombinationUnsupported`` when the OS is older
    ///   than iOS 27 or the active format rejects the combination;
    ///   ``PRMSessionError/virtualDeviceManualControlUnsupported(_:)`` on a virtual
    ///   multi-camera device when any axis is locked (the constituent cameras' auto exposure
    ///   overrides it).
    func prm_setExposure(
        aperture: PRMExposureValue<Float> = .current,
        shutterSeconds: PRMExposureValue<Double> = .current,
        iso: PRMExposureValue<Float> = .current,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard #available(iOS 27.0, *), isExposureModeSupported(.custom) else {
            throw PRMSessionError.exposureCombinationUnsupported
        }
        let allAuto = aperture.isAuto && shutterSeconds.isAuto && iso.isAuto
        if !allAuto, prm_isVirtualMultiCameraDevice {
            throw PRMSessionError.virtualDeviceManualControlUnsupported(deviceType)
        }
        let values = prm_resolvedExposureValues(aperture: aperture, shutterSeconds: shutterSeconds, iso: iso)
        guard activeFormat.supportsExposureModeCustom(
            lensAperture: values.aperture,
            duration: values.duration,
            iso: values.iso
        ) else {
            throw PRMSessionError.exposureCombinationUnsupported
        }
        let fullManual = !aperture.isAuto && !shutterSeconds.isAuto && !iso.isAuto
        try prm_withConfigurationLock {
            if fullManual {
                prm_disableExposureAutoTracking()
            } else {
                prm_restoreExposureAutoTracking()
            }
            setExposureModeCustom(
                lensAperture: values.aperture,
                duration: values.duration,
                iso: values.iso
            ) { time in completion?(time) }
        }
    }

    /// Limits how fast auto exposure may move the aperture (iOS 27), as the ratio of
    /// aperture area between consecutive frames: `1.1` allows 10 % more or less light per
    /// frame. `0` restores the system's own pacing (faster in preview, slower while
    /// recording). Values between 0 and 1 are raised to 1.
    func prm_setAutoApertureRateLimit(_ ratio: Float) throws {
        guard #available(iOS 27.0, *) else {
            throw PRMSessionError.unsupportedConfiguration("Aperture rate limiting requires iOS 27")
        }
        let value: Float = ratio <= 0 ? 0 : max(ratio, 1)
        try prm_withConfigurationLock {
            autoExposureLensApertureRateLimit = value
        }
    }

    // MARK: - Exposure signals

    /// Exposure signals auto exposure is currently reacting to (iOS 27). Empty before that.
    var prm_activeExposureSignals: Set<PRMExposureSignal> {
        guard #available(iOS 27.0, *) else { return [] }
        return PRMExposureSignal.set(from: activeExposureSignals)
    }

    /// Chooses which scene signals auto exposure may weigh (iOS 27). `nil` hands the choice
    /// back to the system (`automaticallyEnablesExposureSignals = true`). Unsupported
    /// signals are dropped, since assigning one raises an exception.
    func prm_setExposureSignals(_ signals: Set<PRMExposureSignal>?) throws {
        guard #available(iOS 27.0, *) else {
            throw PRMSessionError.unsupportedConfiguration("Exposure signals require iOS 27")
        }
        try prm_withConfigurationLock {
            guard let signals else {
                automaticallyEnablesExposureSignals = true
                return
            }
            automaticallyEnablesExposureSignals = false
            let supported = supportedExposureSignals
            enabledExposureSignals = Set(signals.map(\.avSignal)).intersection(supported)
        }
    }
}

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// Maps each axis to the SDK value: sentinels for `.auto` / `.current`, clamped numbers
    /// for `.fixed`.
    @available(iOS 27.0, *)
    func prm_resolvedExposureValues(
        aperture: PRMExposureValue<Float>,
        shutterSeconds: PRMExposureValue<Double>,
        iso: PRMExposureValue<Float>
    ) -> (aperture: Float, duration: CMTime, iso: Float) {
        let format = activeFormat
        let resolvedAperture: Float = switch aperture {
        case .auto: Self.autoLensAperture
        case .current: Self.currentLensAperture
        case let .fixed(value): min(max(value, format.minLensAperture), max(format.maxLensAperture, format.minLensAperture))
        }
        let resolvedDuration: CMTime = switch shutterSeconds {
        case .auto: Self.autoExposureDuration
        case .current: Self.currentExposureDuration
        case let .fixed(seconds): prm_clampedDuration(CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000))
        }
        let resolvedISO: Float = switch iso {
        case .auto: Self.autoISO
        case .current: Self.currentISO
        case let .fixed(value): min(max(value, format.minISO), format.maxISO)
        }
        return (resolvedAperture, resolvedDuration, resolvedISO)
    }
}
