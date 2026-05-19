import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    /// Sets manual ISO at the current exposure duration. Sentinel `currentExposureDuration`
    /// keeps whatever shutter speed the auto-exposure system last selected.
    ///
    /// Equivalent to calling ``prm_setCustomExposure(duration:iso:completion:)`` with
    /// `duration = AVCaptureDevice.currentExposureDuration`.
    func prm_setISO(_ iso: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        try prm_setCustomExposure(
            duration: AVCaptureDevice.currentExposureDuration,
            iso: iso,
            completion: completion
        )
    }

    /// Sets manual shutter speed (exposure duration in seconds) at the current ISO.
    /// Sentinel `currentISO` keeps whatever ISO the auto-exposure system last selected.
    ///
    /// `1/500s` is `1.0 / 500.0`. Values outside the active format's supported range are
    /// clamped by ``prm_setCustomExposure(duration:iso:completion:)``.
    func prm_setShutterSpeed(seconds: Double, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        let duration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
        try prm_setCustomExposure(
            duration: duration,
            iso: AVCaptureDevice.currentISO,
            completion: completion
        )
    }

    /// Supported ISO range for the active format.
    func prm_isoRange() -> ClosedRange<Float> {
        activeFormat.minISO ... activeFormat.maxISO
    }

    /// Supported shutter-speed range (in seconds) for the active format.
    func prm_shutterSpeedRange() -> ClosedRange<Double> {
        let minSec = CMTimeGetSeconds(activeFormat.minExposureDuration)
        let maxSec = CMTimeGetSeconds(activeFormat.maxExposureDuration)
        return minSec ... maxSec
    }
}
