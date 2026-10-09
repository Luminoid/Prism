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

    /// Common white balance presets.
    ///
    /// On iOS 26 and later, every preset except `.flash` resolves to Apple's calibrated
    /// temperature and tint for that illuminant (`AVCaptureDevice.WhiteBalanceTemperatureAndTintValues`
    /// `.tungsten`, `.fluorescent`, `.daylight`, `.cloudy`, `.shadow`), which can carry a
    /// non-zero tint. ``temperatureAndTint`` returns those values; ``temperature`` stays the
    /// nominal Kelvin used on earlier systems.
    enum PRMWhiteBalancePreset: Sendable, CaseIterable {
        case tungsten       // ~3200K
        case fluorescent    // ~4000K
        case flash          // ~5400K
        case daylight       // ~5500K
        case cloudy         // ~6500K
        case shade          // ~7500K

        /// The values ``AVCaptureDevice/prm_lockWhiteBalance(preset:completion:)`` locks to:
        /// Apple's calibrated values on iOS 26+ (all presets but `.flash`), otherwise the
        /// nominal ``temperature`` with neutral tint.
        public var temperatureAndTint: PRMTemperatureAndTint {
            if #available(iOS 26.0, *), let values = systemValues {
                return PRMTemperatureAndTint(temperature: values.temperature, tint: values.tint)
            }
            return PRMTemperatureAndTint(temperature: temperature, tint: 0)
        }

        @available(iOS 26.0, *)
        private var systemValues: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? {
            switch self {
            case .tungsten: .tungsten
            case .fluorescent: .fluorescent
            case .daylight: .daylight
            case .cloudy: .cloudy
            case .shade: .shadow
            case .flash: nil
            }
        }

        /// Nominal Kelvin for the preset.
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

    /// Sets the white balance mode.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device doesn't
    ///   support `mode`, or AVFoundation's lock error.
    func prm_setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) throws {
        guard isWhiteBalanceModeSupported(mode) else {
            throw PRMSessionError.unsupportedConfiguration(
                "White balance mode \(mode.prm_name) isn't supported; \(prm_supportedModesText(prm_supportedWhiteBalanceModes.map(\.prm_name)))"
            )
        }
        try prm_withConfigurationLock {
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
    /// ``PRMCamera/switchDevice(type:position:)``. Throws
    /// ``PRMSessionError/unsupportedConfiguration(_:)`` when the device can't lock white
    /// balance to custom gains. `completion` only runs when this returns without throwing.
    func prm_lockWhiteBalance(
        _ values: PRMTemperatureAndTint,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        guard isWhiteBalanceModeSupported(.locked),
              isLockingWhiteBalanceWithCustomDeviceGainsSupported
        else {
            throw PRMSessionError.unsupportedConfiguration("\(localizedName) can't lock white balance to custom gains")
        }
        if prm_isVirtualMultiCameraDevice {
            throw PRMSessionError.virtualDeviceManualControlUnsupported(deviceType)
        }

        let avTemp = Self.WhiteBalanceTemperatureAndTintValues(
            temperature: values.temperature,
            tint: values.tint
        )
        let gains = deviceWhiteBalanceGains(for: avTemp)
        let clampedGains = Self.clampGains(gains, for: self)

        try prm_withConfigurationLock {
            setWhiteBalanceModeLocked(with: clampedGains) { time in completion?(time) }
        }
    }

    /// Async-completion variant of ``prm_lockWhiteBalance(_:completion:)``. Awaits the
    /// AVFoundation commit handler so the caller knows the WB lock has actually landed
    /// on the device before returning. Useful right before a still capture where the
    /// EXIF must reflect the user's locked Kelvin.
    ///
    /// Gives up after `timeout` seconds with ``PRMSessionError/unsupportedConfiguration(_:)``,
    /// since no frame confirms the lock while the session is stopped or interrupted.
    func prm_lockWhiteBalance(_ values: PRMTemperatureAndTint, timeout: TimeInterval = 5) async throws -> CMTime {
        try await Self.prm_awaitDeviceCommit(
            timeout: timeout,
            timeoutMessage: "No frame confirmed the white balance lock within \(Int(timeout)) s"
        ) { resume in
            try prm_lockWhiteBalance(values) { time in resume(.success(time)) }
        }
    }

    /// Locks white balance to a named preset: Apple's calibrated values on iOS 26+, the
    /// nominal Kelvin with neutral tint before that (see ``PRMWhiteBalancePreset/temperatureAndTint``).
    /// Goes through the same gain conversion and clamping as
    /// ``prm_lockWhiteBalance(_:completion:)``, since the SDK raises on out-of-range gains.
    func prm_lockWhiteBalance(
        preset: PRMWhiteBalancePreset,
        completion: (@Sendable (CMTime) -> Void)? = nil
    ) throws {
        try prm_lockWhiteBalance(preset.temperatureAndTint, completion: completion)
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
        return Self.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1.0), maxGain),
            greenGain: min(max(gains.greenGain, 1.0), maxGain),
            blueGain: min(max(gains.blueGain, 1.0), maxGain)
        )
    }
}
