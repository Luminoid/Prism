import AVFoundation
import CoreMedia
import os

/// Provides exposure control utilities for `AVCaptureDevice`.
///
/// Supports exposure bias (EV compensation), manual ISO/duration, and mode control.
///
/// ```swift
/// try PRMExposureHelper.setExposureTargetBias(1.0, on: device)
/// let range = PRMExposureHelper.exposureBiasRange(for: device) // -8.0...8.0
/// ```
public enum PRMExposureHelper: Sendable {
    // MARK: - Exposure Bias

    /// Sets the exposure target bias (EV compensation).
    ///
    /// The bias is clamped to the device's supported range.
    /// - Parameters:
    ///   - bias: The target exposure bias in EV (e.g., -2.0 to +2.0).
    ///   - device: The capture device to configure.
    ///   - completion: Called when the exposure adjustment completes, with the actual timestamp.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setExposureTargetBias(
        _ bias: Float,
        on device: AVCaptureDevice,
        completion: (@Sendable (CMTime) -> Void)? = nil,
    ) throws {
        let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
        try device.lockForConfiguration()
        device.setExposureTargetBias(clamped) { time in
            completion?(time)
        }
        device.unlockForConfiguration()
    }

    // MARK: - Exposure Mode

    /// Sets the exposure mode on the device.
    ///
    /// - Parameters:
    ///   - mode: The desired exposure mode.
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setExposureMode(
        _ mode: AVCaptureDevice.ExposureMode,
        on device: AVCaptureDevice,
    ) throws {
        guard device.isExposureModeSupported(mode) else {
            PRMLogger.session.warning("Exposure mode \(String(describing: mode)) not supported")
            return
        }
        try device.lockForConfiguration()
        device.exposureMode = mode
        device.unlockForConfiguration()
    }

    // MARK: - Custom Exposure

    /// Sets manual exposure with specific duration and ISO.
    ///
    /// Both values are clamped to the device's supported ranges.
    /// - Parameters:
    ///   - duration: The exposure duration (shutter speed).
    ///   - iso: The sensor sensitivity (ISO).
    ///   - device: The capture device to configure.
    ///   - completion: Called when the exposure adjustment completes.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setCustomExposure(
        duration: CMTime,
        iso: Float,
        on device: AVCaptureDevice,
        completion: (@Sendable (CMTime) -> Void)? = nil,
    ) throws {
        guard device.isExposureModeSupported(.custom) else {
            PRMLogger.session.warning("Custom exposure mode not supported")
            return
        }

        let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let clampedDuration = clampDuration(duration, for: device)

        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { time in
            completion?(time)
        }
        device.unlockForConfiguration()
    }

    // MARK: - Queries

    /// The supported exposure bias range (e.g., -8.0...8.0).
    public static func exposureBiasRange(for device: AVCaptureDevice) -> ClosedRange<Float> {
        device.minExposureTargetBias ... device.maxExposureTargetBias
    }

    /// The supported ISO range for the active format.
    public static func isoRange(for device: AVCaptureDevice) -> ClosedRange<Float> {
        device.activeFormat.minISO ... device.activeFormat.maxISO
    }

    /// The supported exposure duration range for the active format.
    public static func durationRange(for device: AVCaptureDevice) -> (min: CMTime, max: CMTime) {
        (device.activeFormat.minExposureDuration, device.activeFormat.maxExposureDuration)
    }

    /// The current exposure target bias.
    public static func currentExposureTargetBias(for device: AVCaptureDevice) -> Float {
        device.exposureTargetBias
    }

    /// The current ISO value.
    public static func currentISO(for device: AVCaptureDevice) -> Float {
        device.iso
    }

    /// The current exposure duration.
    public static func currentExposureDuration(for device: AVCaptureDevice) -> CMTime {
        device.exposureDuration
    }

    // MARK: - Private

    private static func clampDuration(_ duration: CMTime, for device: AVCaptureDevice) -> CMTime {
        let minDuration = device.activeFormat.minExposureDuration
        let maxDuration = device.activeFormat.maxExposureDuration

        let durationSeconds = CMTimeGetSeconds(duration)
        let minSeconds = CMTimeGetSeconds(minDuration)
        let maxSeconds = CMTimeGetSeconds(maxDuration)

        let clamped = min(max(durationSeconds, minSeconds), maxSeconds)
        return CMTimeMakeWithSeconds(clamped, preferredTimescale: duration.timescale)
    }
}
