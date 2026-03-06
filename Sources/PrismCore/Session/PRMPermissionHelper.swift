import AVFoundation
#if canImport(UIKit)
    import UIKit
#endif

/// Wraps AVFoundation camera and microphone permission flow.
///
/// Provides a unified permission status enum and async request methods:
/// ```swift
/// if PRMPermissionHelper.cameraStatus() == .notDetermined {
///     let granted = await PRMPermissionHelper.requestCameraAccess()
/// }
/// ```
public enum PRMPermissionHelper: Sendable {
    // MARK: - Permission Status

    /// Unified permission status mapping `AVAuthorizationStatus` values.
    public enum PermissionStatus: Sendable {
        /// The user has granted access.
        case authorized
        /// The user has explicitly denied access.
        case denied
        /// Access is restricted by device policy (e.g., parental controls).
        case restricted
        /// The user has not yet been asked.
        case notDetermined
    }

    // MARK: - Camera

    /// Returns the current camera permission status.
    public static func cameraStatus() -> PermissionStatus {
        mapStatus(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Requests camera access and returns whether it was granted.
    public static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Microphone

    /// Returns the current microphone permission status.
    public static func microphoneStatus() -> PermissionStatus {
        mapStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Requests microphone access and returns whether it was granted.
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Settings URL

    /// Returns a URL to open the app's Settings page, or `nil` on platforms that don't support it.
    public static func settingsURL() -> URL? {
        #if canImport(UIKit)
            URL(string: UIApplication.openSettingsURLString)
        #else
            nil
        #endif
    }

    // MARK: - Internal

    private static func mapStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
