import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    // MARK: - Exposure Mode

    /// Sets the exposure mode. When returning to auto / continuous-auto, also re-enables
    /// the auto-tracking knobs `prm_setCustomExposure` disabled, so face-AE and
    /// subject-area-change recovery come back for a normal Camera-app feel.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device doesn't
    ///   support `mode`, or AVFoundation's lock error.
    func prm_setExposureMode(_ mode: AVCaptureDevice.ExposureMode) throws {
        guard isExposureModeSupported(mode) else {
            throw PRMSessionError.unsupportedConfiguration(
                "Exposure mode \(mode.prm_name) isn't supported; \(prm_supportedModesText(prm_supportedExposureModes.map(\.prm_name)))"
            )
        }
        try prm_withConfigurationLock {
            if mode != .custom {
                prm_restoreExposureAutoTracking()
            }
            exposureMode = mode
        }
    }

    // MARK: - Exposure Bias (EV)

    /// Sets the exposure target bias (EV compensation), clamped to the supported range.
    ///
    /// - Parameters:
    ///   - bias: EV compensation; clamped to `minExposureTargetBias...maxExposureTargetBias`.
    ///   - completion: Fires when the adjustment completes, with the actual timestamp.
    func prm_setExposureBias(_ bias: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        let clamped = min(max(bias, minExposureTargetBias), maxExposureTargetBias)
        try prm_withConfigurationLock {
            setExposureTargetBias(clamped) { time in completion?(time) }
        }
    }

    // MARK: - Custom Exposure (Manual)

    /// Sets manual exposure with specific duration and ISO. Both are clamped to the active
    /// format's supported ranges.
    ///
    /// `AVCaptureDevice.currentExposureDuration` and `AVCaptureDevice.currentISO` are
    /// sentinels AVFoundation recognizes as "keep current"; they're passed through
    /// untouched so callers (e.g. `prm_setISO` setting only ISO, `prm_setShutterSpeed`
    /// setting only duration) actually get the keep-current semantics they ask for.
    /// Clamping them would either NaN-poison the duration or peg ISO to maxISO.
    ///
    /// Also turns off **every** auto-tracking knob that fights manual exposure on iPhone:
    ///
    /// - `isSubjectAreaChangeMonitoringEnabled = false` — when the system detects a
    ///   substantial scene change it posts `AVCaptureDeviceSubjectAreaDidChangeNotification`,
    ///   and the system itself often re-applies continuous-auto. Disabling monitoring
    ///   stops the re-application.
    /// - `automaticallyAdjustsFaceDrivenAutoExposureEnabled = false` and
    ///   `isFaceDrivenAutoExposureEnabled = false` — face-driven AE is a *parallel*
    ///   exposure system that AVFoundation runs alongside the user-controlled
    ///   `exposureMode`. When a face is detected it can override the manual value
    ///   on the next frame, which presents as "ISO jumped back to auto" the moment
    ///   any face enters the preview. iPhone 14+ defaults face-AE ON.
    /// - `automaticallyAdjustsVideoHDREnabled = false` (when supported) — auto-HDR can
    ///   re-bracket exposures behind the manual lock, also visible as drift.
    ///
    /// These are documented in Apple dev-forum thread 737498 as the missing pieces for
    /// "ISO won't stick" symptoms; AVCamManual predates them so doesn't apply them, but
    /// the iPhone-14-era face-AE behavior has been the canonical bite for years.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device has no
    ///   custom exposure mode, ``PRMSessionError/virtualDeviceManualControlUnsupported(_:)``
    ///   on a virtual multi-camera device, or AVFoundation's lock error. `completion` only
    ///   runs when this returns without throwing.
    func prm_setCustomExposure(
        duration: CMTime,
        iso: Float,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard isExposureModeSupported(.custom) else {
            throw PRMSessionError.unsupportedConfiguration("\(localizedName) has no custom exposure mode")
        }
        // Virtual multi-camera devices (`.builtInTripleCamera`, `.builtInDualCamera`,
        // `.builtInDualWideCamera`) silently reject manual exposure: the constituent
        // physical cameras' auto-AE systems keep re-asserting themselves, so the saved
        // photo's EXIF shows continuous-auto values even though `setExposureModeCustom`
        // returned success. Per Apple's white-balance docs: "exposure duration, ISO,
        // aperture, white balance gains, or lens position may change when the device
        // switches from one camera to the other." Fail fast with a clear error rather
        // than silently doing nothing — caller should switch to `.builtInWideAngleCamera`
        // via `PRMCamera.switchDevice(type:position:)` first.
        if prm_isVirtualMultiCameraDevice {
            throw PRMSessionError.virtualDeviceManualControlUnsupported(deviceType)
        }
        let clampedISO: Float = (iso == Self.currentISO)
            ? Self.currentISO
            : min(max(iso, activeFormat.minISO), activeFormat.maxISO)
        let clampedDuration: CMTime = (duration.isValid && duration != Self.currentExposureDuration)
            ? prm_clampedDuration(duration)
            : duration
        try prm_withConfigurationLock {
            prm_disableExposureAutoTracking()
            setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { time in completion?(time) }
        }
    }

    /// Async-completion variant of ``prm_setCustomExposure(duration:iso:completion:)``.
    /// Awaits the AVFoundation commit handler — which can lag up to ~3 s on long shutter
    /// durations (Apple dev-forum 751112) — so the caller knows the manual values have
    /// actually landed on the device before returning. Returns the commit timestamp.
    ///
    /// **Don't await inside a slider drag** — continuous setters fire 30+ calls/sec and
    /// each commit serializes the actor. Prefer the fire-and-forget overload for live
    /// adjustment; use this when you need the committed state to be authoritative before
    /// the next step (e.g. before capturing a still where the EXIF must reflect the user's
    /// manual values exactly).
    ///
    /// AVFoundation confirms the change on a frame, so with the session stopped or
    /// interrupted nothing confirms it: the call gives up after `timeout` seconds with
    /// ``PRMSessionError/unsupportedConfiguration(_:)``.
    func prm_setCustomExposure(duration: CMTime, iso: Float, timeout: TimeInterval = 5) async throws -> CMTime {
        try await Self.prm_awaitDeviceCommit(
            timeout: timeout,
            timeoutMessage: "No frame confirmed the custom exposure within \(Int(timeout)) s"
        ) { resume in
            try prm_setCustomExposure(duration: duration, iso: iso) { time in resume(.success(time)) }
        }
    }

    /// Whether a still capture can carry a manual exposure: the manual-exposure bracket
    /// ``PRMPhotoCapture`` fires for ``PRMPhotoSettings/manualExposureOverride`` and for a
    /// device in `.custom`. Virtual multi-camera devices can't (their constituent cameras'
    /// auto exposure overrides the values), and from iOS 27 AVFoundation raises
    /// `NSInvalidArgumentException` on a manual bracket from a format that refuses custom
    /// exposure at the current values, so on iOS 27 the active format also has to accept it.
    var prm_supportsManualExposureCapture: Bool {
        guard isExposureModeSupported(.custom), !prm_isVirtualMultiCameraDevice else { return false }
        guard #available(iOS 27.0, *) else { return true }
        return activeFormat.supportsExposureModeCustom(
            lensAperture: Self.currentLensAperture,
            duration: Self.currentExposureDuration,
            iso: Self.currentISO
        )
    }

    // MARK: - Focus

    /// Sets focus point + mode and exposure point + mode in a single configuration block.
    /// Each axis is skipped when the device doesn't support its point of interest or mode.
    ///
    /// Coordinates are in *device* space (`0,0` = top-left of camera sensor) and are
    /// clamped into `0...1`. Most callers convert from view coordinates via
    /// `PRMPreviewView.texturePoint(fromViewPoint:)`. A `nil` `exposureMode` focuses without
    /// touching exposure, so a manual exposure stays.
    func prm_setFocusAndExposure(
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode?,
        at devicePoint: CGPoint,
        monitorSubjectAreaChange: Bool = false
    ) throws {
        let devicePoint = Self.prm_clampedUnitPoint(devicePoint)
        try prm_withConfigurationLock {
            if isFocusPointOfInterestSupported, isFocusModeSupported(focusMode) {
                focusPointOfInterest = devicePoint
                self.focusMode = focusMode
            }
            if let exposureMode, isExposurePointOfInterestSupported, isExposureModeSupported(exposureMode) {
                exposurePointOfInterest = devicePoint
                self.exposureMode = exposureMode
            }
            #if !os(macOS)
                isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
            #endif
        }
    }

    /// Sets only the exposure point and mode, leaving focus alone. Used while Cinematic
    /// Video is enabled, where any focus-mode change raises `NSInvalidArgumentException`.
    func prm_setExposurePointOfInterest(_ devicePoint: CGPoint, mode: AVCaptureDevice.ExposureMode) throws {
        guard isExposurePointOfInterestSupported, isExposureModeSupported(mode) else { return }
        try prm_withConfigurationLock {
            exposurePointOfInterest = Self.prm_clampedUnitPoint(devicePoint)
            exposureMode = mode
        }
    }

    // MARK: - Rect of Interest (iOS 26)

    /// Sets focus and exposure to a rectangle of interest (iOS 26), which meters and focuses
    /// on a region instead of the system's default box around a point.
    ///
    /// `rect` is in device space (`0...1`, origin top-left). It's clamped into the unit
    /// square and grown to `minFocusRectOfInterestSize` / `minExposureRectOfInterestSize`
    /// around its center, because AVFoundation raises `NSInvalidArgumentException` for
    /// smaller rects. Setting a rect also moves the point of interest to its center; the
    /// mode is set afterwards because the SDK only applies a new rect on a mode change.
    ///
    /// Falls back to the point overload at the rect's center when the OS is older than
    /// iOS 26 or the device doesn't support rects for that axis. A `nil` `exposureMode`
    /// focuses without touching exposure.
    func prm_setFocusAndExposure(
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode?,
        in rect: CGRect,
        monitorSubjectAreaChange: Bool = false
    ) throws {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard #available(iOS 26.0, *) else {
            try prm_setFocusAndExposure(
                focusMode: focusMode,
                exposureMode: exposureMode,
                at: center,
                monitorSubjectAreaChange: monitorSubjectAreaChange
            )
            return
        }
        try prm_withConfigurationLock {
            if isFocusPointOfInterestSupported, isFocusModeSupported(focusMode) {
                if isFocusRectOfInterestSupported {
                    focusRectOfInterest = Self.prm_clampedRectOfInterest(rect, minimumSize: minFocusRectOfInterestSize)
                } else {
                    focusPointOfInterest = center
                }
                self.focusMode = focusMode
            }
            if let exposureMode, isExposurePointOfInterestSupported, isExposureModeSupported(exposureMode) {
                if isExposureRectOfInterestSupported {
                    exposureRectOfInterest = Self.prm_clampedRectOfInterest(rect, minimumSize: minExposureRectOfInterestSize)
                } else {
                    exposurePointOfInterest = center
                }
                self.exposureMode = exposureMode
            }
            isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
        }
    }

    /// The focus rectangle AVFoundation uses by default for a point of interest (iOS 26), in
    /// device space. Use it to size a focus indicator to what the camera actually meters.
    /// `nil` before iOS 26 or when the device doesn't support focus rects.
    func prm_defaultFocusRect(for devicePoint: CGPoint) -> CGRect? {
        guard #available(iOS 26.0, *), isFocusRectOfInterestSupported else { return nil }
        let rect = defaultRectForFocusPoint(ofInterest: devicePoint)
        return rect.isNull ? nil : rect
    }
}

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// Clamps a rectangle of interest into the unit square and grows it (around its center)
    /// to at least `minimumSize`. Pure, so it's unit-testable without a device.
    static func prm_clampedRectOfInterest(_ rect: CGRect, minimumSize: CGSize) -> CGRect {
        let standardized = rect.standardized
        let width = min(max(standardized.width, minimumSize.width, 0), 1)
        let height = min(max(standardized.height, minimumSize.height, 0), 1)
        let originX = min(max(standardized.midX - width / 2, 0), 1 - width)
        let originY = min(max(standardized.midY - height / 2, 0), 1 - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Turn off every parallel-AE system that would otherwise overwrite manual values
    /// on the next frame. Called from `prm_setCustomExposure` while the device is
    /// already locked for configuration — does not lock/unlock itself.
    func prm_disableExposureAutoTracking() {
        #if !os(macOS)
            isSubjectAreaChangeMonitoringEnabled = false
            // Face-driven AE / AF are iOS 15.4+ but documented to exist back to iOS 13.
            // The pair (`automaticallyAdjusts…` + `is…`) is the canonical "turn this
            // whole subsystem off" recipe; setting only one is undefined.
            if responds(to: Selector(("setAutomaticallyAdjustsFaceDrivenAutoExposureEnabled:"))) {
                automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            }
            if responds(to: Selector(("setFaceDrivenAutoExposureEnabled:"))), isFaceDrivenAutoExposureEnabled {
                isFaceDrivenAutoExposureEnabled = false
            }
            if activeFormat.isVideoHDRSupported, automaticallyAdjustsVideoHDREnabled {
                automaticallyAdjustsVideoHDREnabled = false
                prm_noteDisabledByPrism(.videoHDR)
            }
        #endif
    }

    /// Inverse of `prm_disableExposureAutoTracking`. Called from `prm_setExposureMode`
    /// whenever the destination is not `.custom`, so the user gets Camera-app-like
    /// auto behavior back as soon as they tap the Auto chip. Auto video HDR comes back only
    /// if `prm_disableExposureAutoTracking` turned it off, so an explicit
    /// ``prm_setVideoHDR(_:)`` choice survives.
    func prm_restoreExposureAutoTracking() {
        #if !os(macOS)
            if responds(to: Selector(("setAutomaticallyAdjustsFaceDrivenAutoExposureEnabled:"))),
               !automaticallyAdjustsFaceDrivenAutoExposureEnabled {
                automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
            }
            if prm_clearDisabledByPrism(.videoHDR), activeFormat.isVideoHDRSupported, !automaticallyAdjustsVideoHDREnabled {
                automaticallyAdjustsVideoHDREnabled = true
            }
        #endif
    }

    /// `duration` clamped to the active format's exposure range. Compares in `CMTime` and
    /// returns the format's own bound when out of range: converting through seconds and
    /// back at the caller's timescale can round to just outside the range (or to zero at a
    /// coarse timescale), and `setExposureModeCustom` raises on that.
    func prm_clampedDuration(_ duration: CMTime) -> CMTime {
        Self.prm_clampedDuration(
            duration,
            min: activeFormat.minExposureDuration,
            max: activeFormat.maxExposureDuration
        )
    }

    /// Pure core of ``prm_clampedDuration(_:)``. A non-numeric `duration` becomes `lower`.
    static func prm_clampedDuration(_ duration: CMTime, min lower: CMTime, max upper: CMTime) -> CMTime {
        guard duration.isNumeric else { return lower }
        if CMTimeCompare(duration, lower) < 0 { return lower }
        if CMTimeCompare(duration, upper) > 0 { return upper }
        return duration
    }
}
