import AVFoundation

/// Configuration for setting up a camera session.
///
/// Provides sensible defaults for a photo/video capture session.
/// Customize before passing to `PRMCameraSessionManager`.
public struct PRMCameraConfiguration: Sendable {
    /// The session preset controlling output quality.
    public var sessionPreset: AVCaptureSession.Preset

    /// The initial camera position.
    public var cameraPosition: AVCaptureDevice.Position

    /// Whether to include an audio input device.
    public var includesAudio: Bool

    /// Whether to include a video data output for real-time frame processing (filters).
    public var includesVideoDataOutput: Bool

    /// Whether to include a photo output for still capture.
    public var includesPhotoOutput: Bool

    /// The pixel format for video data output. Defaults to 32BGRA (required by Metal + CIImage pipeline).
    public var videoPixelFormat: OSType

    /// Creates a camera configuration with sensible defaults.
    ///
    /// - Parameters:
    ///   - sessionPreset: Output quality preset. Defaults to `.photo`.
    ///   - cameraPosition: Initial camera. Defaults to `.back`.
    ///   - includesAudio: Include audio input. Defaults to `true`.
    ///   - includesVideoDataOutput: Include video data output for filtering. Defaults to `true`.
    ///   - includesPhotoOutput: Include photo output. Defaults to `true`.
    ///   - videoPixelFormat: Pixel format for video frames. Defaults to `kCVPixelFormatType_32BGRA`.
    public init(
        sessionPreset: AVCaptureSession.Preset = .photo,
        cameraPosition: AVCaptureDevice.Position = .back,
        includesAudio: Bool = true,
        includesVideoDataOutput: Bool = true,
        includesPhotoOutput: Bool = true,
        videoPixelFormat: OSType = kCVPixelFormatType_32BGRA,
    ) {
        self.sessionPreset = sessionPreset
        self.cameraPosition = cameraPosition
        self.includesAudio = includesAudio
        self.includesVideoDataOutput = includesVideoDataOutput
        self.includesPhotoOutput = includesPhotoOutput
        self.videoPixelFormat = videoPixelFormat
    }
}
