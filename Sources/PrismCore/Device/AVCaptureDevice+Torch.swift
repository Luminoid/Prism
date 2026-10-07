import AVFoundation

public extension AVCaptureDevice {
    /// Torch mode with optional brightness level.
    enum PRMTorchMode: Sendable, Equatable {
        /// Torch off.
        case off
        /// Torch on at the given level (0...1). Values ≤0 are clamped to a small minimum.
        case on(level: Float)
        /// System decides based on scene conditions.
        case auto
    }

    /// Applies a torch mode. Turning the torch off on a device without one is a no-op.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device has no
    ///   torch or doesn't support the mode (`.auto` isn't universal), AVFoundation's lock
    ///   error, or the error from `setTorchModeOn(level:)` (e.g., thermal limit reached).
    func prm_setTorch(_ mode: PRMTorchMode) throws {
        guard hasTorch else {
            if mode == .off { return }
            throw PRMSessionError.unsupportedConfiguration("\(localizedName) has no torch")
        }
        let avMode: AVCaptureDevice.TorchMode = switch mode {
        case .off: .off
        case .on: .on
        case .auto: .auto
        }
        guard isTorchModeSupported(avMode) else {
            throw PRMSessionError.unsupportedConfiguration("Torch mode \(avMode.rawValue) isn't supported by \(localizedName)")
        }
        try prm_withConfigurationLock {
            switch mode {
            case .off:
                torchMode = .off
            case let .on(level):
                // setTorchModeOn requires level > 0; smallest legal value is .leastNormalMagnitude.
                let bounded = min(max(level, .leastNormalMagnitude), Self.maxAvailableTorchLevel)
                try setTorchModeOn(level: bounded)
            case .auto:
                torchMode = .auto
            }
        }
    }
}
