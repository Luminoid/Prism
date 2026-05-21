import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    // MARK: - Exposure Mode

    /// Sets the exposure mode if supported.
    func prm_setExposureMode(_ mode: AVCaptureDevice.ExposureMode) throws {
        guard isExposureModeSupported(mode) else { return }
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        exposureMode = mode
    }

    // MARK: - Exposure Bias (EV)

    /// Sets the exposure target bias (EV compensation), clamped to the supported range.
    ///
    /// - Parameter completion: Fires when the adjustment completes, with the actual timestamp.
    func prm_setExposureBias(_ bias: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        let clamped = min(max(bias, minExposureTargetBias), maxExposureTargetBias)
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        setExposureTargetBias(clamped) { time in completion?(time) }
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
    func prm_setCustomExposure(
        duration: CMTime,
        iso: Float,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard isExposureModeSupported(.custom) else { return }
        let clampedISO: Float = (iso == AVCaptureDevice.currentISO)
            ? AVCaptureDevice.currentISO
            : min(max(iso, activeFormat.minISO), activeFormat.maxISO)
        let clampedDuration: CMTime = (duration.isValid && duration != AVCaptureDevice.currentExposureDuration)
            ? Self.clampDuration(duration, for: self)
            : duration
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { time in completion?(time) }
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
        try lockForConfiguration()
        defer { unlockForConfiguration() }

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

    // MARK: - Private

    private static func clampDuration(_ duration: CMTime, for device: AVCaptureDevice) -> CMTime {
        let minDur = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxDur = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let cur = CMTimeGetSeconds(duration)
        let clamped = min(max(cur, minDur), maxDur)
        return CMTimeMakeWithSeconds(clamped, preferredTimescale: duration.timescale)
    }
}
