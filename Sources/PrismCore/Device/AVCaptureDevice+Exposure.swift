import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    // MARK: - Exposure Mode

    /// Sets the exposure mode if supported. When returning to auto / continuous-auto,
    /// also re-enables the auto-tracking knobs `prm_setCustomExposure` disabled, so
    /// face-AE and subject-area-change recovery come back for a normal Camera-app feel.
    func prm_setExposureMode(_ mode: AVCaptureDevice.ExposureMode) throws {
        guard isExposureModeSupported(mode) else { return }
        try withConfigurationLock {
            if mode != .custom {
                prm_restoreExposureAutoTracking()
            }
            exposureMode = mode
        }
    }

    // MARK: - Exposure Bias (EV)

    /// Sets the exposure target bias (EV compensation), clamped to the supported range.
    ///
    /// - Parameter completion: Fires when the adjustment completes, with the actual timestamp.
    func prm_setExposureBias(_ bias: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        let clamped = min(max(bias, minExposureTargetBias), maxExposureTargetBias)
        try withConfigurationLock {
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
    func prm_setCustomExposure(
        duration: CMTime,
        iso: Float,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard isExposureModeSupported(.custom) else { return }
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
        let clampedISO: Float = (iso == AVCaptureDevice.currentISO)
            ? AVCaptureDevice.currentISO
            : min(max(iso, activeFormat.minISO), activeFormat.maxISO)
        let clampedDuration: CMTime = (duration.isValid && duration != AVCaptureDevice.currentExposureDuration)
            ? Self.clampDuration(duration, for: self)
            : duration
        try withConfigurationLock {
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
    func prm_setCustomExposure(duration: CMTime, iso: Float) async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try prm_setCustomExposure(duration: duration, iso: iso) { time in
                    continuation.resume(returning: time)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Turn off every parallel-AE system that would otherwise overwrite manual values
    /// on the next frame. Called from `prm_setCustomExposure` while the device is
    /// already locked for configuration — does not lock/unlock itself.
    private func prm_disableExposureAutoTracking() {
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
            }
        #endif
    }

    /// Inverse of `prm_disableExposureAutoTracking`. Called from `prm_setExposureMode`
    /// whenever the destination is not `.custom`, so the user gets Camera-app-like
    /// auto behavior back as soon as they tap the Auto chip.
    private func prm_restoreExposureAutoTracking() {
        #if !os(macOS)
            if responds(to: Selector(("setAutomaticallyAdjustsFaceDrivenAutoExposureEnabled:"))),
               !automaticallyAdjustsFaceDrivenAutoExposureEnabled {
                automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
            }
            if activeFormat.isVideoHDRSupported, !automaticallyAdjustsVideoHDREnabled {
                automaticallyAdjustsVideoHDREnabled = true
            }
        #endif
    }

    // MARK: - Focus

    /// Sets focus point + mode and exposure point + mode in a single configuration block.
    ///
    /// Coordinates are in *device* space (`0,0` = top-left of camera sensor).
    /// Most callers convert from view coordinates via `PRMPreviewView.texturePoint(fromViewPoint:)`.
    func prm_setFocusAndExposure(
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        at devicePoint: CGPoint,
        monitorSubjectAreaChange: Bool = false
    ) throws {
        try withConfigurationLock {
            if isFocusPointOfInterestSupported, isFocusModeSupported(focusMode) {
                focusPointOfInterest = devicePoint
                self.focusMode = focusMode
            }
            if isExposurePointOfInterestSupported, isExposureModeSupported(exposureMode) {
                exposurePointOfInterest = devicePoint
                self.exposureMode = exposureMode
            }
            #if !os(macOS)
                isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
            #endif
        }
    }

    // MARK: - Private

    private static func clampDuration(_ duration: CMTime, for device: AVCaptureDevice) -> CMTime {
        let minDur = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxDur = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let cur = CMTimeGetSeconds(duration)
        let clamped = min(max(cur, minDur), maxDur)
        return CMTimeMakeWithSeconds(clamped, preferredTimescale: duration.timescale)
    }
}
