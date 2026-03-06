import AVFoundation
#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Video Rotation Angle

/// Video rotation angles corresponding to device orientations.
public enum PRMVideoRotationAngle: Sendable {
    /// Portrait: 90° rotation.
    public static let portrait: CGFloat = 90
    /// Portrait upside-down: 270° rotation.
    public static let portraitUpsideDown: CGFloat = 270
    /// Landscape right: 0° rotation (native camera orientation).
    public static let landscapeRight: CGFloat = 0
    /// Landscape left: 180° rotation.
    public static let landscapeLeft: CGFloat = 180
}

// MARK: - UIDeviceOrientation → Rotation Angle

#if canImport(UIKit)
    public extension UIDeviceOrientation {
        /// Returns the video rotation angle for this device orientation, or `nil` for non-spatial orientations.
        var prm_videoRotationAngle: CGFloat? {
            switch self {
            case .portrait: PRMVideoRotationAngle.portrait
            case .portraitUpsideDown: PRMVideoRotationAngle.portraitUpsideDown
            case .landscapeLeft: PRMVideoRotationAngle.landscapeRight // Intentionally swapped
            case .landscapeRight: PRMVideoRotationAngle.landscapeLeft  // Intentionally swapped
            default: nil
            }
        }
    }
#endif

// MARK: - UIInterfaceOrientation → Rotation Angle

#if canImport(UIKit)
    public extension UIInterfaceOrientation {
        /// Returns the video rotation angle for this interface orientation, or `nil` for unknown.
        var prm_videoRotationAngle: CGFloat? {
            switch self {
            case .portrait: PRMVideoRotationAngle.portrait
            case .portraitUpsideDown: PRMVideoRotationAngle.portraitUpsideDown
            case .landscapeLeft: PRMVideoRotationAngle.landscapeLeft
            case .landscapeRight: PRMVideoRotationAngle.landscapeRight
            default: nil
            }
        }
    }
#endif

// MARK: - AVCaptureConnection Rotation

public extension AVCaptureConnection {
    /// Safely updates the video rotation angle if the connection supports it.
    ///
    /// - Parameter angle: The rotation angle in degrees (0, 90, 180, 270).
    func prm_setVideoRotationAngle(_ angle: CGFloat) {
        if isVideoRotationAngleSupported(angle) {
            videoRotationAngle = angle
        }
    }
}
