import AVFoundation

/// Errors thrown by the camera session pipeline.
public enum PRMSessionError: Error, Sendable, Equatable {
    /// The user has not granted camera access.
    case notAuthorized

    /// No video device is available for the requested camera position.
    case noVideoDevice(AVCaptureDevice.Position)

    /// No video device of the requested type is available for the requested position
    /// (e.g. asked for `.builtInWideAngleCamera` on a position that doesn't have one).
    case noDeviceOfType(AVCaptureDevice.DeviceType, AVCaptureDevice.Position)

    /// Could not create an input from the discovered device.
    case cannotCreateDeviceInput(String)

    /// `AVCaptureSession.canAddInput`/`canAddOutput` returned `false`.
    case cannotAttachToSession(String)

    /// Session emitted a runtime error notification.
    case runtime(AVError)

    /// Photo capture failed before delivering a final photo.
    case photoCaptureFailed(String)

    /// Video recording failed.
    case videoRecordingFailed(String)

    /// Operation cancelled (e.g., async task was cancelled mid-capture).
    case cancelled

    /// The active device is a virtual multi-camera (`.builtInTripleCamera`,
    /// `.builtInDualCamera`, `.builtInDualWideCamera`) whose constituent
    /// auto-AE / auto-AWB systems silently re-assert themselves, defeating
    /// `setExposureModeCustom` / `setWhiteBalanceModeLocked`. Switch to
    /// `.builtInWideAngleCamera` via `PRMCamera.switchDevice(type:position:)`
    /// before re-issuing the manual call.
    case virtualDeviceManualControlUnsupported(AVCaptureDevice.DeviceType)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notAuthorized, .notAuthorized): true
        case (.cancelled, .cancelled): true
        case let (.noVideoDevice(a), .noVideoDevice(b)): a == b
        case let (.noDeviceOfType(typeA, posA), .noDeviceOfType(typeB, posB)): typeA == typeB && posA == posB
        case let (.cannotCreateDeviceInput(a), .cannotCreateDeviceInput(b)): a == b
        case let (.cannotAttachToSession(a), .cannotAttachToSession(b)): a == b
        case let (.runtime(a), .runtime(b)): a.code == b.code
        case let (.photoCaptureFailed(a), .photoCaptureFailed(b)): a == b
        case let (.videoRecordingFailed(a), .videoRecordingFailed(b)): a == b
        case let (.virtualDeviceManualControlUnsupported(a), .virtualDeviceManualControlUnsupported(b)): a == b
        default: false
        }
    }
}

// MARK: - LocalizedError

extension PRMSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Camera access has not been granted."
        case let .noVideoDevice(position):
            "No video device available for camera position \(position.rawValue)."
        case let .noDeviceOfType(type, position):
            "No \(type.rawValue) device available at camera position \(position.rawValue)."
        case let .cannotCreateDeviceInput(reason):
            "Cannot create video input: \(reason)"
        case let .cannotAttachToSession(reason):
            "Cannot attach to capture session: \(reason)"
        case let .runtime(error):
            "Capture session runtime error: \(error.localizedDescription)"
        case let .photoCaptureFailed(reason):
            "Photo capture failed: \(reason)"
        case let .videoRecordingFailed(reason):
            "Video recording failed: \(reason)"
        case .cancelled:
            "Operation cancelled."
        case let .virtualDeviceManualControlUnsupported(deviceType):
            "Manual exposure / white-balance lock is unsupported on virtual multi-camera device \(deviceType.rawValue). Switch to .builtInWideAngleCamera first."
        }
    }
}
