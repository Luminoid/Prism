import AVFoundation

/// Sendable snapshot of the running camera's runtime state.
///
/// `PRMCamera` publishes this on its `stateStream`. Consumers in UI code can `for await` and
/// update labels/buttons without crossing actor boundaries themselves.
public struct PRMCameraState: Sendable, Equatable {
    /// Whether the underlying `AVCaptureSession` is currently running.
    public var isRunning: Bool

    /// Current zoom factor on the active video device.
    public var zoomFactor: CGFloat

    /// Current torch mode.
    public var torchMode: AVCaptureDevice.TorchMode

    /// Current torch brightness level (0...1). Always 0 when torch is off.
    public var torchLevel: Float

    /// Current focus mode.
    public var focusMode: AVCaptureDevice.FocusMode

    /// Current lens position (0.0 = near focus, 1.0 = far focus).
    public var lensPosition: Float

    /// Current exposure mode.
    public var exposureMode: AVCaptureDevice.ExposureMode

    /// Current exposure target bias (EV).
    public var exposureBias: Float

    /// Current ISO value.
    public var iso: Float

    /// Current exposure duration in seconds, or `nil` if invalid.
    public var exposureDurationSeconds: Double?

    /// Current white balance mode.
    public var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode

    /// Current white balance temperature in Kelvin.
    public var whiteBalanceTemperature: Float

    /// Current white balance tint.
    public var whiteBalanceTint: Float

    /// Currently active stabilization mode on the video data output connection (if any).
    public var activeStabilizationMode: AVCaptureVideoStabilizationMode

    /// Currently active frame rate, or `nil` if no custom rate is set.
    public var frameRate: Float64?

    /// Whether the active format currently has video HDR enabled.
    public var isVideoHDREnabled: Bool

    /// Whether low-light boost is currently active.
    public var isLowLightBoostActive: Bool

    /// Whether session is currently interrupted.
    public var isInterrupted: Bool

    /// The physical lens AVFoundation is *currently* feeding frames from on a virtual
    /// (multi-lens) device. iOS 16+ exposes this via
    /// `AVCaptureDevice.activePrimaryConstituentDevice.deviceType`; on single-lens devices
    /// (or when AVFoundation hasn't resolved a primary yet) this is `nil`. Use it to
    /// match the active lens chip in the UI — at certain zooms AVFoundation falls back
    /// to the wide lens with digital zoom even when the user picked the telephoto chip
    /// (low light, close subject, etc.), and that override shows up here.
    public var activePrimaryDeviceType: AVCaptureDevice.DeviceType?

    public init(
        isRunning: Bool = false,
        zoomFactor: CGFloat = 1.0,
        torchMode: AVCaptureDevice.TorchMode = .off,
        torchLevel: Float = 0,
        focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus,
        lensPosition: Float = 0,
        exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure,
        exposureBias: Float = 0,
        iso: Float = 0,
        exposureDurationSeconds: Double? = nil,
        whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance,
        whiteBalanceTemperature: Float = 5500,
        whiteBalanceTint: Float = 0,
        activeStabilizationMode: AVCaptureVideoStabilizationMode = .off,
        frameRate: Float64? = nil,
        isVideoHDREnabled: Bool = false,
        isLowLightBoostActive: Bool = false,
        isInterrupted: Bool = false,
        activePrimaryDeviceType: AVCaptureDevice.DeviceType? = nil
    ) {
        self.isRunning = isRunning
        self.zoomFactor = zoomFactor
        self.torchMode = torchMode
        self.torchLevel = torchLevel
        self.focusMode = focusMode
        self.lensPosition = lensPosition
        self.exposureMode = exposureMode
        self.exposureBias = exposureBias
        self.iso = iso
        self.exposureDurationSeconds = exposureDurationSeconds
        self.whiteBalanceMode = whiteBalanceMode
        self.whiteBalanceTemperature = whiteBalanceTemperature
        self.whiteBalanceTint = whiteBalanceTint
        self.activeStabilizationMode = activeStabilizationMode
        self.frameRate = frameRate
        self.isVideoHDREnabled = isVideoHDREnabled
        self.isLowLightBoostActive = isLowLightBoostActive
        self.isInterrupted = isInterrupted
        self.activePrimaryDeviceType = activePrimaryDeviceType
    }
}
