import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    // MARK: - Types

    /// A temperature/tint pair for white balance control.
    struct PRMTemperatureAndTint: Sendable, Equatable {
        /// Color temperature in Kelvin (e.g., 2700 warm → 7500 cool).
        public var temperature: Float
        /// Tint adjustment (green ↔ magenta).
        public var tint: Float

        public init(temperature: Float, tint: Float = 0) {
            self.temperature = temperature
            self.tint = tint
        }
    }

    /// Common white balance presets with standard Kelvin values.
    enum PRMWhiteBalancePreset: Sendable, CaseIterable {
        case tungsten       // ~3200K
        case fluorescent    // ~4000K
        case flash          // ~5400K
        case daylight       // ~5500K
        case cloudy         // ~6500K
        case shade          // ~7500K

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

    /// Sets the white balance mode if supported.
    func prm_setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) throws {
        guard isWhiteBalanceModeSupported(mode) else { return }
        try withConfigurationLock {
            whiteBalanceMode = mode
        }
    }

    // MARK: - Lock to Temperature / Tint

    /// Locks white balance at the given temperature and tint.
    ///
    /// Throws ``PRMSessionError/virtualDeviceManualControlUnsupported(_:)`` when the
    /// active device is a virtual multi-camera — its constituent cameras' auto-AWB
    /// systems silently re-assert themselves, so the lock has no visible effect on the
    /// preview or saved photo. Switch to `.builtInWideAngleCamera` first via
    /// ``PRMCamera/switchDevice(type:position:)``.
    func prm_lockWhiteBalance(
        _ values: PRMTemperatureAndTint,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard isWhiteBalanceModeSupported(.locked),
              isLockingWhiteBalanceWithCustomDeviceGainsSupported
        else { return }
        if prm_isVirtualMultiCameraDevice {
            throw PRMSessionError.virtualDeviceManualControlUnsupported(deviceType)
        }

        let avTemp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: values.temperature,
            tint: values.tint
        )
        let gains = deviceWhiteBalanceGains(for: avTemp)
        let clampedGains = Self.clampGains(gains, for: self)

        try withConfigurationLock {
            setWhiteBalanceModeLocked(with: clampedGains) { time in completion?(time) }
        }
    }

    /// Async-completion variant of ``prm_lockWhiteBalance(_:completion:)``. Awaits the
    /// AVFoundation commit handler so the caller knows the WB lock has actually landed
    /// on the device before returning. Useful right before a still capture where the
    /// EXIF must reflect the user's locked Kelvin.
    func prm_lockWhiteBalance(_ values: PRMTemperatureAndTint) async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try prm_lockWhiteBalance(values) { time in
                    continuation.resume(returning: time)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Locks white balance to a named preset (neutral tint).
    func prm_lockWhiteBalance(
        preset: PRMWhiteBalancePreset,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        try prm_lockWhiteBalance(
            PRMTemperatureAndTint(temperature: preset.temperature, tint: 0),
            completion: completion
        )
    }

    // MARK: - Query

    /// Returns the current temperature and tint values.
    func prm_currentTemperatureAndTint() -> PRMTemperatureAndTint {
        let gains = Self.clampGains(deviceWhiteBalanceGains, for: self)
        let values = temperatureAndTintValues(for: gains)
        return PRMTemperatureAndTint(temperature: values.temperature, tint: values.tint)
    }

    // MARK: - Private

    private static func clampGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1.0), maxGain),
            greenGain: min(max(gains.greenGain, 1.0), maxGain),
            blueGain: min(max(gains.blueGain, 1.0), maxGain)
        )
    }
}
