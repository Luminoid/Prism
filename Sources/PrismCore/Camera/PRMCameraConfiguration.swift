import AVFoundation

/// Configuration for setting up a camera session.
///
/// Sensible defaults match a photo + filtered-video preview workflow. Customize before passing
/// to ``PRMCameraSession.configure(_:)``.
public struct PRMCameraConfiguration: Sendable {
    /// The session preset controlling output quality.
    public var sessionPreset: AVCaptureSession.Preset

    /// The initial camera position.
    public var cameraPosition: AVCaptureDevice.Position

    /// Preferred device type discovery order. The session uses the first available type
    /// for the requested position.
    public var deviceTypes: [AVCaptureDevice.DeviceType]

    /// Whether to include an audio input device.
    public var includesAudio: Bool

    /// Whether to add a video data output for real-time frame processing (filters).
    public var includesVideoDataOutput: Bool

    /// Whether to add a photo output for still capture.
    public var includesPhotoOutput: Bool

    /// Whether to add a movie file output for video recording.
    public var includesMovieFileOutput: Bool

    /// The pixel format for video data output. Defaults to 32BGRA (Metal + Core Image friendly).
    public var videoPixelFormat: OSType

    /// Photo quality prioritization ceiling. Per-capture requests may select up to this level.
    /// (Replaces the deprecated `isAutoStillImageStabilizationEnabled` flag.)
    public var maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization

    /// iOS 17+: enable overlapping capture phases for faster shot-to-shot.
    public var enableResponsiveCapture: Bool

    /// iOS 17+: deliver proxy photos at the time of capture and finalize in the background.
    public var enableAutoDeferredPhotoDelivery: Bool

    /// iOS 17+: shorten shutter lag by buffering frames.
    public var enableZeroShutterLag: Bool

    /// iPad-only (iOS 16+): allow camera capture while the app is multitasking.
    public var enableMultitaskingCameraAccess: Bool

    public init(
        sessionPreset: AVCaptureSession.Preset = .photo,
        cameraPosition: AVCaptureDevice.Position = .back,
        deviceTypes: [AVCaptureDevice.DeviceType] = Self.defaultDeviceTypes,
        includesAudio: Bool = true,
        includesVideoDataOutput: Bool = true,
        includesPhotoOutput: Bool = true,
        includesMovieFileOutput: Bool = false,
        videoPixelFormat: OSType = kCVPixelFormatType_32BGRA,
        maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality,
        enableResponsiveCapture: Bool = true,
        enableAutoDeferredPhotoDelivery: Bool = true,
        enableZeroShutterLag: Bool = true,
        enableMultitaskingCameraAccess: Bool = false
    ) {
        self.sessionPreset = sessionPreset
        self.cameraPosition = cameraPosition
        self.deviceTypes = deviceTypes
        self.includesAudio = includesAudio
        self.includesVideoDataOutput = includesVideoDataOutput
        self.includesPhotoOutput = includesPhotoOutput
        self.includesMovieFileOutput = includesMovieFileOutput
        self.videoPixelFormat = videoPixelFormat
        self.maxPhotoQualityPrioritization = maxPhotoQualityPrioritization
        self.enableResponsiveCapture = enableResponsiveCapture
        self.enableAutoDeferredPhotoDelivery = enableAutoDeferredPhotoDelivery
        self.enableZeroShutterLag = enableZeroShutterLag
        self.enableMultitaskingCameraAccess = enableMultitaskingCameraAccess
    }

    /// Default device type preference order: triple → dual → dual-wide → wide-angle.
    ///
    /// On macOS only `.builtInWideAngleCamera` is available; the iOS/Catalyst extras are
    /// filtered out by the discovery session at runtime.
    public static var defaultDeviceTypes: [AVCaptureDevice.DeviceType] {
        #if os(macOS)
            [.builtInWideAngleCamera]
        #else
            [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
            ]
        #endif
    }
}
