import AVFoundation
import os

/// Provides torch (flashlight) control utilities for `AVCaptureDevice`.
///
/// Torch is continuously on (unlike flash, which fires momentarily during photo capture).
///
/// ```swift
/// try PRMTorchHelper.setTorchMode(.on(level: 0.5), on: device)
/// PRMTorchHelper.isTorchAvailable(on: device) // true/false
/// ```
public enum PRMTorchHelper: Sendable {
    // MARK: - Types

    /// Torch mode with optional brightness level.
    public enum TorchMode: Sendable, Equatable {
        /// Turn torch on at the specified brightness (0.0–1.0).
        case on(level: Float)
        /// Turn torch off.
        case off
        /// Let the system decide based on scene conditions.
        case auto
    }

    // MARK: - Control

    /// Sets the torch mode on the device.
    ///
    /// - Parameters:
    ///   - mode: The desired torch mode.
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration or torch is unavailable.
    public static func setTorchMode(_ mode: TorchMode, on device: AVCaptureDevice) throws {
        guard device.hasTorch else {
            PRMLogger.session.warning("Device does not have a torch")
            return
        }

        try device.lockForConfiguration()

        switch mode {
        case let .on(level):
            let clampedLevel = min(max(level, 0.0), AVCaptureDevice.maxAvailableTorchLevel)
            try device.setTorchModeOn(level: clampedLevel)
        case .off:
            device.torchMode = .off
        case .auto:
            device.torchMode = .auto
        }

        device.unlockForConfiguration()
    }

    // MARK: - Queries

    /// Whether the device has a torch.
    public static func hasTorch(on device: AVCaptureDevice) -> Bool {
        device.hasTorch
    }

    /// Whether the torch is currently available for use.
    ///
    /// A device may have a torch but it can be temporarily unavailable
    /// (e.g., during certain capture modes or when overheated).
    public static func isTorchAvailable(on device: AVCaptureDevice) -> Bool {
        device.isTorchAvailable
    }

    /// The current torch brightness level (0.0–1.0). Returns 0 when off.
    public static func currentTorchLevel(on device: AVCaptureDevice) -> Float {
        device.torchLevel
    }

    /// Whether the torch is currently active (on or auto and firing).
    public static func isTorchActive(on device: AVCaptureDevice) -> Bool {
        device.isTorchActive
    }
}
