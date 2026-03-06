import AVFoundation
import os

/// Provides video stabilization control for `AVCaptureConnection`.
///
/// Video stabilization is set on the capture connection, not the device.
///
/// ```swift
/// if let connection = videoDataOutput.connection(with: .video) {
///     PRMStabilizationHelper.setPreferredStabilizationMode(.cinematic, on: connection)
/// }
/// ```
public enum PRMStabilizationHelper: Sendable {
    // MARK: - Control

    /// Sets the preferred video stabilization mode on the connection.
    ///
    /// The system may fall back to a less aggressive mode if the preferred mode
    /// is not supported by the current device/format.
    /// - Parameters:
    ///   - mode: The desired stabilization mode.
    ///   - connection: The capture connection to configure.
    public static func setPreferredStabilizationMode(
        _ mode: AVCaptureVideoStabilizationMode,
        on connection: AVCaptureConnection,
    ) {
        guard connection.isVideoStabilizationSupported else {
            PRMLogger.session.warning("Video stabilization not supported on this connection")
            return
        }
        connection.preferredVideoStabilizationMode = mode
    }

    // MARK: - Queries

    /// The currently active stabilization mode (may differ from preferred).
    public static func activeStabilizationMode(
        on connection: AVCaptureConnection,
    ) -> AVCaptureVideoStabilizationMode {
        connection.activeVideoStabilizationMode
    }

    /// Whether video stabilization is supported on this connection.
    public static func isStabilizationSupported(
        on connection: AVCaptureConnection,
    ) -> Bool {
        connection.isVideoStabilizationSupported
    }

    /// The preferred stabilization mode set by the app.
    public static func preferredStabilizationMode(
        on connection: AVCaptureConnection,
    ) -> AVCaptureVideoStabilizationMode {
        connection.preferredVideoStabilizationMode
    }
}
