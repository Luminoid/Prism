import AVFoundation
#if canImport(UIKit)
    import UIKit
#endif

/// Async-await camera + microphone permission helpers.
///
/// ```swift
/// if PRMPermissions.cameraStatus() == .notDetermined {
///     let granted = await PRMPermissions.requestCameraAccess()
/// }
/// ```
public enum PRMPermissions: Sendable {
    /// Unified permission status mapping `AVAuthorizationStatus`.
    public enum Status: Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
    }

    // MARK: - Camera

    public static func cameraStatus() -> Status {
        map(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Requests camera access and returns whether it was granted.
    public static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Microphone

    public static func microphoneStatus() -> Status {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Requests microphone access and returns whether it was granted.
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Settings

    /// URL to open the app's Settings page on platforms that support it.
    public static func settingsURL() -> URL? {
        #if canImport(UIKit)
            URL(string: UIApplication.openSettingsURLString)
        #else
            nil
        #endif
    }

    // MARK: - Internal

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
