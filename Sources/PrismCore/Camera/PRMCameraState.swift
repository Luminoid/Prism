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

    // MARK: iOS 26 / 27 manual controls

    /// Current lens 𝑓-number. Fixed on most hardware; varies with exposure on iOS 27
    /// variable-aperture cameras.
    public var lensAperture: Float

    /// The exposure axes the auto-exposure system is currently driving. All three in the
    /// auto modes, none in full manual, a subset in an iOS 27 priority mode. Before iOS 27
    /// this is derived from ``exposureMode``.
    public var autoExposureAxes: PRMExposureAxes

    /// iOS 27: scene characteristics auto exposure is currently reacting to.
    public var activeExposureSignals: Set<PRMExposureSignal>

    /// iOS 27: whether the virtual device is locked to its ``activePrimaryDeviceType`` lens
    /// (see ``PRMCamera/lockLens(_:)``).
    public var isPrimaryConstituentLocked: Bool

    // MARK: Session health

    /// iOS 26: latest lens smudge detection result. `.disabled` unless detection is on.
    public var lensSmudgeStatus: PRMLensSmudgeStatus

    /// iOS 27: whether low-light video noise reduction is active on the recording (or,
    /// without a movie output, the preview) connection.
    public var isLowLightVideoNoiseReductionActive: Bool

    /// Why the session is interrupted, when ``isInterrupted`` is `true`. iOS 26 adds
    /// `.sensitiveContentMitigationActivated`.
    public var interruptionReason: AVCaptureSession.InterruptionReason?

    /// Thermal / power pressure on the capture device. iOS 27 adds `.batteryStress`.
    public var systemPressure: PRMSystemPressure

    // MARK: Subject tracking and Cinematic Video

    /// iOS 27: whether continuous autofocus subject tracking is enabled.
    public var isContinuousAutoFocusTrackingEnabled: Bool

    /// iOS 27: whether a subject is currently being tracked for focus.
    public var isContinuousAutoFocusTrackingSubjectAcquired: Bool

    /// iOS 27: lens-position bias within the tracked subject's depth (-1 nearest … 1 farthest).
    public var continuousAutoFocusTrackingBias: Float

    /// iOS 26: whether Cinematic Video capture is enabled on the video input.
    public var isCinematicVideoCaptureEnabled: Bool

    /// iOS 26: Cinematic Video simulated aperture (𝑓-number of the depth-of-field effect).
    /// `0` when Cinematic Video is off.
    public var cinematicSimulatedAperture: Float

    /// iOS 26: scene conditions degrading Cinematic Video (e.g. not enough light).
    public var cinematicSceneStatuses: Set<PRMSceneMonitoringStatus>

    /// iOS 27: whether the movie output is recording Cinematic Video metadata.
    public var isCinematicVideoMetadataCaptureEnabled: Bool

    // MARK: Dynamic aspect ratio

    /// iOS 26: the device's current dynamic aspect ratio, or `nil` when the active format
    /// doesn't support dynamic aspect ratios.
    public var dynamicAspectRatio: PRMAspectRatio?

    /// iOS 26: output buffer dimensions for ``dynamicAspectRatio``, or `nil` when unsupported.
    public var dynamicDimensions: PRMVideoDimensions?

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
        activePrimaryDeviceType: AVCaptureDevice.DeviceType? = nil,
        lensAperture: Float = 0,
        autoExposureAxes: PRMExposureAxes = .all,
        activeExposureSignals: Set<PRMExposureSignal> = [],
        isPrimaryConstituentLocked: Bool = false,
        lensSmudgeStatus: PRMLensSmudgeStatus = .disabled,
        isLowLightVideoNoiseReductionActive: Bool = false,
        interruptionReason: AVCaptureSession.InterruptionReason? = nil,
        systemPressure: PRMSystemPressure = .nominal,
        isContinuousAutoFocusTrackingEnabled: Bool = false,
        isContinuousAutoFocusTrackingSubjectAcquired: Bool = false,
        continuousAutoFocusTrackingBias: Float = 0,
        isCinematicVideoCaptureEnabled: Bool = false,
        cinematicSimulatedAperture: Float = 0,
        cinematicSceneStatuses: Set<PRMSceneMonitoringStatus> = [],
        isCinematicVideoMetadataCaptureEnabled: Bool = false,
        dynamicAspectRatio: PRMAspectRatio? = nil,
        dynamicDimensions: PRMVideoDimensions? = nil
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
        self.lensAperture = lensAperture
        self.autoExposureAxes = autoExposureAxes
        self.activeExposureSignals = activeExposureSignals
        self.isPrimaryConstituentLocked = isPrimaryConstituentLocked
        self.lensSmudgeStatus = lensSmudgeStatus
        self.isLowLightVideoNoiseReductionActive = isLowLightVideoNoiseReductionActive
        self.interruptionReason = interruptionReason
        self.systemPressure = systemPressure
        self.isContinuousAutoFocusTrackingEnabled = isContinuousAutoFocusTrackingEnabled
        self.isContinuousAutoFocusTrackingSubjectAcquired = isContinuousAutoFocusTrackingSubjectAcquired
        self.continuousAutoFocusTrackingBias = continuousAutoFocusTrackingBias
        self.isCinematicVideoCaptureEnabled = isCinematicVideoCaptureEnabled
        self.cinematicSimulatedAperture = cinematicSimulatedAperture
        self.cinematicSceneStatuses = cinematicSceneStatuses
        self.isCinematicVideoMetadataCaptureEnabled = isCinematicVideoMetadataCaptureEnabled
        self.dynamicAspectRatio = dynamicAspectRatio
        self.dynamicDimensions = dynamicDimensions
    }
}
