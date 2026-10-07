import AVFoundation

// MARK: - PRMCinematicFocusMode

/// How strongly Cinematic Video holds focus on a subject. Mirrors
/// `AVCaptureDevice.CinematicVideoFocusMode` (iOS 26).
public enum PRMCinematicFocusMode: Sendable, Hashable {
    /// No preference; AVFoundation falls back to weak focus.
    case none
    /// Keep the subject in focus until it leaves the scene.
    case strong
    /// Let the algorithm move focus as subjects gain or lose prominence.
    case weak
}

@available(iOS 26.0, *)
extension PRMCinematicFocusMode {
    init(_ mode: AVCaptureDevice.CinematicVideoFocusMode) {
        switch mode {
        case .strong: self = .strong
        case .weak: self = .weak
        default: self = .none
        }
    }

    var avMode: AVCaptureDevice.CinematicVideoFocusMode {
        switch self {
        case .none: .none
        case .strong: .strong
        case .weak: .weak
        }
    }
}

// MARK: - PRMCinematicFocusRequest

/// A Cinematic Video focus command. Points are normalized device coordinates (`0...1`,
/// origin top-left), the same space as ``PRMCamera/setFocusAndExposure(focusMode:exposureMode:at:monitorSubjectAreaChange:)``.
public enum PRMCinematicFocusRequest: Sendable, Equatable {
    /// Track a subject reported by ``PRMCamera/detectedObjectsStream()`` (its `objectID`).
    case trackObject(id: Int, mode: PRMCinematicFocusMode)
    /// Track whatever subject can be detected at a point.
    case trackPoint(CGPoint, mode: PRMCinematicFocusMode)
    /// Fix focus at the distance of a point (depth-derived), without tracking.
    case fixedPoint(CGPoint, mode: PRMCinematicFocusMode)
}

// MARK: - PRMSceneMonitoringStatus

/// A scene condition that keeps Cinematic Video from working well. Mirrors
/// `AVCaptureSceneMonitoringStatus` (iOS 26). Surface it as a "scene too dark" hint.
public enum PRMSceneMonitoringStatus: Sendable, Hashable {
    /// The scene is too dark for Cinematic Video to work optimally.
    case notEnoughLight
    /// A status added after this version of Prism; the raw AVFoundation string.
    case other(String)

    @available(iOS 26.0, *)
    init(_ status: AVCaptureSceneMonitoringStatus) {
        self = status == .notEnoughLight ? .notEnoughLight : .other(status.rawValue)
    }
}

// MARK: - PRMCinematicMetadataCapture

/// iOS 27: whether the movie file output records Cinematic Video metadata, which lets the
/// Cinematic framework re-edit focus after capture.
public enum PRMCinematicMetadataCapture: Sendable, Equatable {
    /// AVFoundation decides (its default).
    case automatic
    /// Record metadata whenever the output supports it.
    case enabled
    /// Never record metadata.
    case disabled
}
