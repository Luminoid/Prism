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

    /// AVFoundation failed a photo capture or a recording. The `AVError` keeps the code, for
    /// example `.maximumDurationReached`, or `-11872` when the session asked for more
    /// camera hardware than the device has.
    case captureFailed(AVError)

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

    /// The requested exposure combination (an iOS 27 priority mode, or any aperture /
    /// shutter / ISO mix) isn't supported by the active format, or the OS is older than
    /// iOS 27. Check ``PRMCameraDevice/apertureRange`` and
    /// `AVCaptureDevice.prm_supportsExposure(aperture:shutterSeconds:iso:)` first.
    case exposureCombinationUnsupported

    /// The operation isn't available in the session's current configuration: the OS is too
    /// old, the device or format doesn't support it, or another mode excludes it (for
    /// example, focus changes while Cinematic Video is active). The string says which.
    case unsupportedConfiguration(String)

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
        case let (.captureFailed(a), .captureFailed(b)): a.code == b.code
        case let (.videoRecordingFailed(a), .videoRecordingFailed(b)): a == b
        case let (.virtualDeviceManualControlUnsupported(a), .virtualDeviceManualControlUnsupported(b)): a == b
        case (.exposureCombinationUnsupported, .exposureCombinationUnsupported): true
        case let (.unsupportedConfiguration(a), .unsupportedConfiguration(b)): a == b
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
        case let .captureFailed(error):
            "Capture failed: \(error.localizedDescription)"
        case let .videoRecordingFailed(reason):
            "Video recording failed: \(reason)"
        case .cancelled:
            "Operation cancelled."
        case let .virtualDeviceManualControlUnsupported(deviceType):
            "Manual exposure / white-balance lock is unsupported on virtual multi-camera device \(deviceType.rawValue). Switch to .builtInWideAngleCamera first."
        case .exposureCombinationUnsupported:
            "The requested aperture / shutter / ISO combination isn't supported by the active format."
        case let .unsupportedConfiguration(reason):
            "Unsupported in the current configuration: \(reason)"
        }
    }
}
