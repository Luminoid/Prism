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

    /// Applies a torch mode if the device has a torch.
    ///
    /// - Throws: If the device cannot be locked for configuration, or
    ///           `setTorchModeOn(level:)` fails (e.g., thermal limit reached).
    func prm_setTorch(_ mode: PRMTorchMode) throws {
        guard hasTorch else { return }
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        switch mode {
        case .off:
            torchMode = .off
        case let .on(level):
            // setTorchModeOn requires level > 0; smallest legal value is .leastNormalMagnitude.
            let bounded = min(max(level, .leastNormalMagnitude), AVCaptureDevice.maxAvailableTorchLevel)
            try setTorchModeOn(level: bounded)
        case .auto:
            torchMode = .auto
        }
    }
}
