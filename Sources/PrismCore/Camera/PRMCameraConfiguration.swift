import AVFoundation

/// Configuration for setting up a camera session.
///
/// Sensible defaults match a photo + filtered-video preview workflow. Customize before passing
/// to ``PRMCameraSession/configure(_:)``.
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

    /// Whether the video data output drops frames that arrive while the previous one is still
    /// being processed. Default `true` is correct for preview/filter pipelines; set to `false`
    /// for ML / scientific capture where frame-accurate streams matter more than realtime
    /// throughput.
    public var discardsLateVideoFrames: Bool

    /// Photo quality prioritization ceiling. Per-capture requests may select up to this level.
    /// (Replaces the deprecated `isAutoStillImageStabilizationEnabled` flag.)
    public var maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization

    /// iOS 17+: enable overlapping capture phases for faster shot-to-shot.
    public var enableResponsiveCapture: Bool

    /// iOS 17+: deliver proxy photos at the time of capture and finalize in the background.
    public var enableAutoDeferredPhotoDelivery: Bool

    /// iOS 17+: shorten shutter lag by buffering frames.
    public var enableZeroShutterLag: Bool

    /// Enable Live Photo capture on the photo output. When false, the output's
    /// `isLivePhotoCaptureEnabled` is left at the system default (off) so that the
    /// extra movie pipeline isn't allocated for apps that don't use it.
    public var enableLivePhoto: Bool

    /// Enable depth data delivery on the photo output. Required for portrait
    /// effects matte requests at capture time.
    public var enableDepthDataDelivery: Bool

    /// Enable portrait effects matte delivery on the photo output.
    public var enablePortraitEffectsMatteDelivery: Bool

    /// Preferred video stabilization mode for recordings (the movie output connection).
    /// Applied lazily once the connection is available. The video-data output behind the
    /// live preview never gets the latency-heavy cinematic modes: it runs unstabilized in the
    /// photo modes and with iOS 26's `.lowLatency` while a movie output is attached.
    public var preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode

    /// iPad-only (iOS 16+): allow camera capture while the app is multitasking. iPhone returns
    /// `isMultitaskingCameraAccessSupported == false` at runtime; an info log is emitted when
    /// this is true on an unsupported device.
    public var enableMultitaskingCameraAccess: Bool

    /// When `true`, the session selects the `activeFormat` whose `supportedMaxPhotoDimensions`
    /// contains the largest entry — required to unlock 48MP capture on iPhone 14 Pro+ /
    /// 15 Pro+. The `.photo` preset's default activeFormat caps at 12MP regardless of the
    /// device's 48MP capability. Setting this flag picks a 48MP-capable format and raises
    /// the photo output's `maxPhotoDimensions` accordingly.
    ///
    /// **The 48MP-capable format is mutually exclusive with Live Photo capture** — Live
    /// Photo requires a format that streams a parallel movie pipeline, which the 48MP
    /// photo format doesn't expose. Setting both this flag *and* `enableLivePhoto = true`
    /// is undefined; the format promotion wins and Live Photo silently fails. Apps that
    /// need to toggle between modes at runtime should leave this `false` and call
    /// ``PRMCamera/setHighResolutionPhotoFormat(_:)`` per user action.
    ///
    /// Pair with `deviceTypes: [.builtInWideAngleCamera]` — virtual devices (`triple`, `dual`,
    /// `dualWide`) cap at 12MP regardless of format selection. Also disable `enableZeroShutterLag`,
    /// `enableAutoDeferredPhotoDelivery`, `enableLivePhoto` — all substitute 12MP proxy captures.
    public var prefersMaxPhotoDimensionsFormat: Bool

    // MARK: iOS 26 / 27

    /// iOS 26: which outputs start after the first preview frame. `.systemDefault` keeps
    /// AVFoundation's behavior (apps linked on iOS 26+ defer the photo and movie outputs).
    public var deferredStart: PRMDeferredStart

    /// iOS 26: run camera-lens smudge detection. `nil` = off, `.invalid` = once per session
    /// start, `.zero` = continuously, any other time = that interval between runs. Results
    /// land in ``PRMCameraState/lensSmudgeStatus``. Enabling it rebuilds the capture
    /// pipeline, which is why it's set here rather than after start.
    public var lensSmudgeDetectionInterval: CMTime?

    /// iOS 26: let users pick AirPods as a high-quality microphone for recording. Only
    /// applies when ``includesAudio`` is `true`.
    public var enableBluetoothHighQualityRecording: Bool

    /// Attach an `AVCaptureMetadataOutput` at configure time. Without it, Prism attaches one
    /// lazily the first time a feature needs it (subject tracking, Cinematic Video, or
    /// ``metadataObjectTypes``), at the cost of one extra pipeline rebuild then.
    public var includesMetadataOutput: Bool

    /// Extra metadata object types (faces, bodies, pets, …) to deliver on
    /// ``PRMCamera/detectedObjectsStream()``. Types the device can't produce are dropped.
    /// Ignored while Cinematic Video is enabled, which needs its own fixed set.
    public var metadataObjectTypes: [AVMetadataObject.ObjectType]

    /// iOS 26: start with Cinematic Video capture enabled (shallow depth of field and focus
    /// transitions in recorded video). Implies a movie file output. Incompatible with Live
    /// Photo, 48MP formats and depth delivery; `validate()` warns about those. When the first
    /// of `deviceTypes` at `cameraPosition` has no Cinematic Video format (the Triple camera
    /// on Pro iPhones), the session opens the camera that does
    /// (``PRMCameraDevice/cinematicVideoDeviceType(at:)``).
    public var enableCinematicVideo: Bool

    /// iOS 26: rotate HEIC / JPEG still buffers to match earlier hardware's sensor
    /// orientation (for apps that assume it). `nil` leaves the system default. Prism's own
    /// rotation handling doesn't need it.
    public var enableCameraSensorOrientationCompensation: Bool?

    public init(
        sessionPreset: AVCaptureSession.Preset = .photo,
        cameraPosition: AVCaptureDevice.Position = .back,
        deviceTypes: [AVCaptureDevice.DeviceType] = Self.defaultDeviceTypes,
        includesAudio: Bool = true,
        includesVideoDataOutput: Bool = true,
        includesPhotoOutput: Bool = true,
        includesMovieFileOutput: Bool = false,
        videoPixelFormat: OSType = kCVPixelFormatType_32BGRA,
        discardsLateVideoFrames: Bool = true,
        maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality,
        enableResponsiveCapture: Bool = true,
        enableAutoDeferredPhotoDelivery: Bool = true,
        enableZeroShutterLag: Bool = true,
        enableLivePhoto: Bool = false,
        enableDepthDataDelivery: Bool = false,
        enablePortraitEffectsMatteDelivery: Bool = false,
        preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode = .auto,
        enableMultitaskingCameraAccess: Bool = false,
        prefersMaxPhotoDimensionsFormat: Bool = false,
        deferredStart: PRMDeferredStart = .systemDefault,
        lensSmudgeDetectionInterval: CMTime? = nil,
        enableBluetoothHighQualityRecording: Bool = false,
        includesMetadataOutput: Bool = false,
        metadataObjectTypes: [AVMetadataObject.ObjectType] = [],
        enableCinematicVideo: Bool = false,
        enableCameraSensorOrientationCompensation: Bool? = nil
    ) {
        self.sessionPreset = sessionPreset
        self.cameraPosition = cameraPosition
        self.deviceTypes = deviceTypes
        self.includesAudio = includesAudio
        self.includesVideoDataOutput = includesVideoDataOutput
        self.includesPhotoOutput = includesPhotoOutput
        self.includesMovieFileOutput = includesMovieFileOutput
        self.videoPixelFormat = videoPixelFormat
        self.discardsLateVideoFrames = discardsLateVideoFrames
        self.maxPhotoQualityPrioritization = maxPhotoQualityPrioritization
        self.enableResponsiveCapture = enableResponsiveCapture
        self.enableAutoDeferredPhotoDelivery = enableAutoDeferredPhotoDelivery
        self.enableZeroShutterLag = enableZeroShutterLag
        self.enableLivePhoto = enableLivePhoto
        self.enableDepthDataDelivery = enableDepthDataDelivery
        self.enablePortraitEffectsMatteDelivery = enablePortraitEffectsMatteDelivery
        self.preferredVideoStabilizationMode = preferredVideoStabilizationMode
        self.enableMultitaskingCameraAccess = enableMultitaskingCameraAccess
        self.prefersMaxPhotoDimensionsFormat = prefersMaxPhotoDimensionsFormat
        self.deferredStart = deferredStart
        self.lensSmudgeDetectionInterval = lensSmudgeDetectionInterval
        self.enableBluetoothHighQualityRecording = enableBluetoothHighQualityRecording
        self.includesMetadataOutput = includesMetadataOutput
        self.metadataObjectTypes = metadataObjectTypes
        self.enableCinematicVideo = enableCinematicVideo
        self.enableCameraSensorOrientationCompensation = enableCameraSensorOrientationCompensation
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

    /// Logs `.warning`-level diagnostics for known-incompatible flag combinations. Called
    /// from ``PRMCameraSession/configure(_:)`` so misconfigurations surface in Console
    /// without making the init throwing (the constructor stays infallible — these are
    /// "will silently misbehave", not "cannot be constructed"). In DEBUG builds the
    /// hard-conflict cases also `assertionFailure` so the misuse fails fast under the
    /// debugger.
    ///
    /// Conflicts:
    /// - `prefersMaxPhotoDimensionsFormat` + `enableLivePhoto` — the 48MP photo format
    ///   doesn't carry the parallel movie pipeline Live Photo needs. The format
    ///   promotion wins and Live Photo silently fails.
    /// - `prefersMaxPhotoDimensionsFormat` + (`enableZeroShutterLag` /
    ///   `enableAutoDeferredPhotoDelivery`) — both substitute 12MP proxy captures
    ///   regardless of the active format.
    /// - `prefersMaxPhotoDimensionsFormat` on a `deviceTypes` list that includes virtual
    ///   multi-cameras (`.builtInTripleCamera`, `.builtInDualCamera`, `.builtInDualWideCamera`)
    ///   without `.builtInWideAngleCamera` first — virtual devices cap at 12MP regardless
    ///   of the format chosen, so the promotion is a silent no-op until the consumer
    ///   `switchDevice(type: .builtInWideAngleCamera)` themselves.
    func validate() {
        validateCinematicVideo()
        guard prefersMaxPhotoDimensionsFormat else { return }
        if enableLivePhoto {
            PRMLog.warning(
                .session,
                """
                PRMCameraConfiguration: prefersMaxPhotoDimensionsFormat=true is incompatible \
                with enableLivePhoto=true — the 48MP photo format does not stream the parallel \
                movie pipeline Live Photo requires. The format promotion will win and Live Photo \
                will silently fail. Toggle high-res via PRMCamera.setHighResolutionPhotoFormat(_:) \
                per user action instead.
                """
            )
            assertionFailure("prefersMaxPhotoDimensionsFormat + enableLivePhoto are mutually exclusive")
        }
        if enableZeroShutterLag {
            PRMLog.warning(
                .session,
                """
                PRMCameraConfiguration: prefersMaxPhotoDimensionsFormat=true substitutes 12MP proxy captures \
                when combined with enableZeroShutterLag=true; the 48MP capture you toggled on never actually fires.
                """
            )
        }
        if enableAutoDeferredPhotoDelivery {
            PRMLog.warning(
                .session,
                """
                PRMCameraConfiguration: prefersMaxPhotoDimensionsFormat=true substitutes 12MP proxy captures \
                when combined with enableAutoDeferredPhotoDelivery=true; the 48MP capture you toggled on \
                never actually fires.
                """
            )
        }
        #if !os(macOS)
            let virtualTypes: Set<AVCaptureDevice.DeviceType> = [
                .builtInTripleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
            ]
            if deviceTypes.first.map({ virtualTypes.contains($0) }) == true,
               !deviceTypes.contains(.builtInWideAngleCamera) {
                PRMLog.warning(
                    .session,
                    """
                    PRMCameraConfiguration: prefersMaxPhotoDimensionsFormat=true but deviceTypes \
                    starts with a virtual multi-camera and does not list .builtInWideAngleCamera. \
                    Virtual devices cap at 12MP regardless of activeFormat — the high-res promotion \
                    will silently no-op. Pair with deviceTypes: [.builtInWideAngleCamera] or call \
                    PRMCamera.switchDevice(type: .builtInWideAngleCamera) before enabling high-res.
                    """
                )
            }
        #endif
    }

    /// Cinematic Video runs its own depth pipeline and movie path; Live Photo, the 48MP
    /// formats and photo depth delivery all compete with it. AVFoundation turns the losers
    /// off silently (or refuses the format), so say so up front.
    private func validateCinematicVideo() {
        guard enableCinematicVideo else { return }
        if enableLivePhoto {
            PRMLog.warning(
                .session,
                "PRMCameraConfiguration: enableCinematicVideo=true attaches a movie output, which disables Live Photo (enableLivePhoto=true will have no effect)."
            )
        }
        if prefersMaxPhotoDimensionsFormat {
            PRMLog.warning(
                .session,
                "PRMCameraConfiguration: enableCinematicVideo=true switches to a Cinematic Video format, overriding prefersMaxPhotoDimensionsFormat."
            )
        }
        if enableDepthDataDelivery || enablePortraitEffectsMatteDelivery {
            PRMLog.warning(
                .session,
                "PRMCameraConfiguration: enableCinematicVideo=true is incompatible with photo depth / portrait matte delivery; expect them to be unavailable."
            )
        }
    }
}
