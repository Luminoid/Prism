import AVFoundation

/// A lens descriptor for one physical camera in a virtual device.
///
/// `displayZoomFactor` is normalized so the wide lens = 1× (matching Apple Camera convention).
/// `focalLength35mm` is the raw 35mm-equivalent focal length computed from the format's field
/// of view at this zoom factor — **unsnapped**. Use ``snapping(to:tolerance:)`` if you want
/// to round to a marketing-friendly value.
public struct PRMLens: Sendable, Equatable {
    /// The raw `AVCaptureDevice.videoZoomFactor` to switch to this lens.
    public let zoomFactor: CGFloat

    /// User-facing zoom multiplier normalized so the wide lens = 1×.
    public let displayZoomFactor: CGFloat

    /// Approximate 35mm-equivalent focal length in millimeters.
    public let focalLength35mm: Double

    /// The constituent device type this lens represents on a virtual (multi-lens)
    /// device: `.builtInUltraWideCamera`, `.builtInWideAngleCamera`, `.builtInTelephotoCamera`.
    /// `nil` on single-lens devices or when the type isn't derivable from the available
    /// AVFoundation metadata. Used to match against
    /// `PRMCameraState.activePrimaryDeviceType` so UIs can highlight the lens AVFoundation
    /// is actually feeding (which can differ from the user's selection in low light).
    public let deviceType: AVCaptureDevice.DeviceType?

    public init(
        zoomFactor: CGFloat,
        displayZoomFactor: CGFloat,
        focalLength35mm: Double,
        deviceType: AVCaptureDevice.DeviceType? = nil
    ) {
        self.zoomFactor = zoomFactor
        self.displayZoomFactor = displayZoomFactor
        self.focalLength35mm = focalLength35mm
        self.deviceType = deviceType
    }

    /// Returns a new lens with `focalLength35mm` snapped to the lowest standard value within
    /// `tolerance` (default 20%). Helpful for displaying marketing-friendly values
    /// (e.g., 13 mm, 24 mm, 77 mm).
    ///
    /// `videoFieldOfView` on virtual devices consistently overestimates focal length, so
    /// among all candidates within tolerance, the lowest is the closest physical match.
    public func snapping(
        to standards: [Int] = Self.standardFocalLengths,
        tolerance: Double = 0.2
    ) -> Self {
        let candidates = standards.filter { abs(Double($0) - focalLength35mm) <= Double($0) * tolerance }
        let snapped = candidates.min().map(Double.init) ?? focalLength35mm
        return Self(
            zoomFactor: zoomFactor,
            displayZoomFactor: displayZoomFactor,
            focalLength35mm: snapped,
            deviceType: deviceType
        )
    }

    /// Standard phone-camera 35mm-equivalent focal lengths.
    public static let standardFocalLengths: [Int] = [13, 15, 23, 24, 26, 48, 50, 52, 65, 70, 77, 120, 200]
}
