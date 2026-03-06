import AVFoundation
import CoreMedia
import os

/// Provides white balance control utilities for `AVCaptureDevice`.
///
/// Supports mode control, temperature/tint locking, and common presets.
///
/// ```swift
/// try PRMWhiteBalanceHelper.lockWhiteBalance(preset: .daylight, on: device)
/// let current = PRMWhiteBalanceHelper.currentTemperatureAndTint(for: device)
/// ```
public enum PRMWhiteBalanceHelper: Sendable {
    // MARK: - Types

    /// A temperature and tint pair for white balance control.
    public struct TemperatureAndTint: Sendable, Equatable {
        /// Color temperature in Kelvin (e.g., 2700 warm → 7500 cool).
        public let temperature: Float
        /// Tint adjustment (green ↔ magenta).
        public let tint: Float

        public init(temperature: Float, tint: Float) {
            self.temperature = temperature
            self.tint = tint
        }
    }

    /// Common white balance presets with standard Kelvin values.
    public enum Preset: Sendable, CaseIterable {
        case tungsten       // ~3200K — indoor incandescent
        case fluorescent    // ~4000K — indoor fluorescent
        case daylight       // ~5500K — direct sunlight
        case flash          // ~5400K — camera flash
        case cloudy         // ~6500K — overcast sky
        case shade          // ~7500K — open shade

        /// The Kelvin temperature for this preset.
        public var temperature: Float {
            switch self {
            case .tungsten: 3200
            case .fluorescent: 4000
            case .flash: 5400
            case .daylight: 5500
            case .cloudy: 6500
            case .shade: 7500
            }
        }
    }

    // MARK: - Mode Control

    /// Sets the white balance mode on the device.
    ///
    /// - Parameters:
    ///   - mode: The desired white balance mode (.locked, .autoWhiteBalance, .continuousAutoWhiteBalance).
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setWhiteBalanceMode(
        _ mode: AVCaptureDevice.WhiteBalanceMode,
        on device: AVCaptureDevice,
    ) throws {
        guard device.isWhiteBalanceModeSupported(mode) else {
            PRMLogger.session.warning("White balance mode \(String(describing: mode)) not supported")
            return
        }
        try device.lockForConfiguration()
        device.whiteBalanceMode = mode
        device.unlockForConfiguration()
    }

    // MARK: - Temperature & Tint

    /// Locks white balance at the specified temperature and tint.
    ///
    /// - Parameters:
    ///   - temperatureAndTint: The desired temperature/tint values.
    ///   - device: The capture device to configure.
    ///   - completion: Called when the adjustment completes.
    /// - Throws: If the device cannot be locked for configuration.
    public static func lockWhiteBalance(
        temperatureAndTint: TemperatureAndTint,
        on device: AVCaptureDevice,
        completion: (@Sendable (CMTime) -> Void)? = nil,
    ) throws {
        guard device.isWhiteBalanceModeSupported(.locked) else {
            PRMLogger.session.warning("Locked white balance mode not supported")
            return
        }
        guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            PRMLogger.session.warning("Locking white balance with custom gains not supported")
            return
        }

        let avTemp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: temperatureAndTint.temperature,
            tint: temperatureAndTint.tint,
        )
        let gains = device.deviceWhiteBalanceGains(for: avTemp)
        let clampedGains = clampGains(gains, for: device)

        try device.lockForConfiguration()
        device.setWhiteBalanceModeLocked(with: clampedGains) { time in
            completion?(time)
        }
        device.unlockForConfiguration()
    }

    /// Locks white balance at a preset temperature with neutral tint.
    ///
    /// - Parameters:
    ///   - preset: The white balance preset.
    ///   - device: The capture device to configure.
    ///   - completion: Called when the adjustment completes.
    /// - Throws: If the device cannot be locked for configuration.
    public static func lockWhiteBalance(
        preset: Preset,
        on device: AVCaptureDevice,
        completion: (@Sendable (CMTime) -> Void)? = nil,
    ) throws {
        let tempAndTint = TemperatureAndTint(temperature: preset.temperature, tint: 0)
        try lockWhiteBalance(temperatureAndTint: tempAndTint, on: device, completion: completion)
    }

    // MARK: - Queries

    /// Returns the current temperature and tint values.
    public static func currentTemperatureAndTint(for device: AVCaptureDevice) -> TemperatureAndTint {
        let gains = clampGains(device.deviceWhiteBalanceGains, for: device)
        let avTemp = device.temperatureAndTintValues(for: gains)
        return TemperatureAndTint(temperature: avTemp.temperature, tint: avTemp.tint)
    }

    /// Returns the current white balance mode.
    public static func currentWhiteBalanceMode(for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceMode {
        device.whiteBalanceMode
    }

    // MARK: - Private

    /// Clamps RGB gains to the device's maximum.
    private static func clampGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for device: AVCaptureDevice,
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1.0), maxGain),
            greenGain: min(max(gains.greenGain, 1.0), maxGain),
            blueGain: min(max(gains.blueGain, 1.0), maxGain),
        )
    }
}
