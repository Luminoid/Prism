import AVFoundation

/// A snapshot of the current capture device's identity and capabilities.
///
/// `AVCaptureDevice` itself is not `Sendable` and is owned by ``PRMCameraSession``. This
/// struct is the safe-to-cross-actor view into the device used by ``PRMCamera`` consumers.
public struct PRMCameraDevice: Sendable, Equatable {
    /// Underlying device unique ID (`AVCaptureDevice.uniqueID`).
    public let uniqueID: String

    /// Device type (e.g., `.builtInWideAngleCamera`, `.builtInTripleCamera`).
    public let deviceType: AVCaptureDevice.DeviceType

    /// Physical camera position.
    public let position: AVCaptureDevice.Position

    /// Human-readable name (localized).
    public let localizedName: String

    /// Minimum supported zoom factor.
    public let minZoomFactor: CGFloat

    /// Maximum supported zoom factor.
    public let maxZoomFactor: CGFloat

    /// Virtual-device switch-over zoom factors. Empty on non-virtual devices.
    public let switchOverZoomFactors: [CGFloat]

    /// Lens descriptors (zoom factor + 35mm-equivalent focal length) for virtual devices.
    /// Empty on single-lens cameras.
    public let lenses: [PRMLens]

    /// Whether the device has a torch (flashlight).
    public let hasTorch: Bool

    /// Whether the device supports flash for photo capture.
    public let hasFlash: Bool

    /// Supported exposure bias range (EV).
    public let exposureBiasRange: ClosedRange<Float>

    /// Supported ISO range for the active format.
    public let isoRange: ClosedRange<Float>

    /// Supported shutter speed range (in seconds) for the active format. Bounds are
    /// `minExposureDuration … maxExposureDuration` evaluated at snapshot time — the
    /// default `.photo` preset typically caps out around 1/3s on most iPhones, so the
    /// upper bound is small. Re-snapshot after a format change (slo-mo, video) to pick
    /// up the new range.
    public let shutterRange: ClosedRange<Double>

    /// Whether the device supports locking white balance with custom temperature/tint.
    public let supportsCustomWhiteBalance: Bool

    /// Whether the device supports any format at ≥120 fps (slow motion).
    public let supportsSlowMotion: Bool

    /// Maximum supported frame rate across all formats.
    public let maxFrameRate: Float64

    /// Largest landscape (`width >= height`) entry across all formats'
    /// `supportedMaxPhotoDimensions`. `nil` when the device exposes no photo dimensions
    /// (e.g. video-only formats). Use this to gate "max resolution" toggles in UI —
    /// virtual devices (`triple`, `dual`, `dualWide`) cap at 12MP (4032×3024) regardless
    /// of format selection; only the physical `.builtInWideAngleCamera` on iPhone 14
    /// Pro+ / 15 Pro+ exposes the 48MP entry (8064×6048).
    public var maxSupportedPhotoDimensions: CMVideoDimensions? {
        maxPhotoDimensions.map { CMVideoDimensions(width: $0.width, height: $0.height) }
    }

    /// Storage for ``maxSupportedPhotoDimensions`` as an `Equatable` type, so `==` can be
    /// synthesized over every field (a hand-written `==` silently misses new ones).
    private let maxPhotoDimensions: PRMVideoDimensions?

    /// Whether the device supports `setFocusModeLocked(lensPosition:)`. Virtual devices
    /// (`triple`, `dual`, `dualWide`) report `isFocusModeSupported(.locked) == true` but
    /// throw `NSInvalidArgumentException` at the setter call (newer iOS releases enforce
    /// `isLockingFocusWithCustomLensPositionSupported` as a separate gate). Gate manual-
    /// focus UI on this flag and require a physical-device swap when false.
    public let supportsCustomLensPosition: Bool

    // MARK: iOS 26 / 27 capabilities (active format unless noted)

    /// iOS 27: supported lens 𝑓-number range, or `nil` when the aperture is fixed.
    public let apertureRange: ClosedRange<Float>?

    /// iOS 27: recommended 𝑓-stops, sorted. One entry means the aperture is fixed.
    public let recommendedApertureStops: [Float]

    /// iOS 27: exposure signals ``PRMCamera/setExposureSignals(_:)`` accepts.
    public let supportedExposureSignals: Set<PRMExposureSignal>

    /// iOS 26: whether focus accepts a rectangle of interest, not just a point.
    public let supportsFocusRectOfInterest: Bool

    /// iOS 26: whether exposure accepts a rectangle of interest, not just a point.
    public let supportsExposureRectOfInterest: Bool

    /// iOS 27: whether ``PRMCamera/lockLens(_:)`` can pin a virtual device to one lens.
    public let supportsPrimaryConstituentLock: Bool

    /// iOS 26: whether lens smudge detection is available in the current configuration.
    public let supportsLensSmudgeDetection: Bool

    /// iOS 27: whether the active format supports low-light video noise reduction.
    public let supportsLowLightVideoNoiseReduction: Bool

    /// iOS 27: whether continuous autofocus subject tracking is available.
    public let supportsContinuousAutoFocusTracking: Bool

    /// iOS 26: whether *any* of this camera's formats supports Cinematic Video (Prism
    /// switches to one when Cinematic Video is enabled).
    public let supportsCinematicVideo: Bool

    /// iOS 26: the camera at this position that Cinematic Video runs on: this one when
    /// ``supportsCinematicVideo``, otherwise the one
    /// ``PRMCamera/setCinematicVideoEnabled(_:targetPhotoOutputAttached:)`` switches to (see
    /// ``cinematicVideoDeviceType(at:)``). `nil` when no camera here supports it.
    public let cinematicVideoDeviceType: AVCaptureDevice.DeviceType?

    /// iOS 26: raw zoom range available while Cinematic Video is enabled, on
    /// ``cinematicVideoDeviceType``.
    public let cinematicZoomRange: ClosedRange<CGFloat>?

    /// iOS 26: simulated-aperture range for Cinematic Video, or `nil` when it can't change.
    public let simulatedApertureRange: ClosedRange<Float>?

    /// iOS 26: frame-rate range available while Cinematic Video is enabled.
    public let cinematicFrameRateRange: ClosedRange<Float64>?

    /// iOS 26: aspect ratios ``PRMCamera/setDynamicAspectRatio(_:)`` accepts. Empty when the
    /// active format doesn't support dynamic aspect ratio.
    public let supportedDynamicAspectRatios: [PRMAspectRatio]

    /// iOS 26: whether the Smart Framing monitor can recommend framings.
    public let supportsSmartFraming: Bool

    public init(
        uniqueID: String,
        deviceType: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position,
        localizedName: String,
        minZoomFactor: CGFloat,
        maxZoomFactor: CGFloat,
        switchOverZoomFactors: [CGFloat],
        lenses: [PRMLens],
        hasTorch: Bool,
        hasFlash: Bool,
        exposureBiasRange: ClosedRange<Float>,
        isoRange: ClosedRange<Float>,
        shutterRange: ClosedRange<Double>,
        supportsCustomWhiteBalance: Bool,
        supportsSlowMotion: Bool,
        maxFrameRate: Float64,
        maxSupportedPhotoDimensions: CMVideoDimensions? = nil,
        supportsCustomLensPosition: Bool = true,
        apertureRange: ClosedRange<Float>? = nil,
        recommendedApertureStops: [Float] = [],
        supportedExposureSignals: Set<PRMExposureSignal> = [],
        supportsFocusRectOfInterest: Bool = false,
        supportsExposureRectOfInterest: Bool = false,
        supportsPrimaryConstituentLock: Bool = false,
        supportsLensSmudgeDetection: Bool = false,
        supportsLowLightVideoNoiseReduction: Bool = false,
        supportsContinuousAutoFocusTracking: Bool = false,
        supportsCinematicVideo: Bool = false,
        cinematicVideoDeviceType: AVCaptureDevice.DeviceType? = nil,
        cinematicZoomRange: ClosedRange<CGFloat>? = nil,
        simulatedApertureRange: ClosedRange<Float>? = nil,
        cinematicFrameRateRange: ClosedRange<Float64>? = nil,
        supportedDynamicAspectRatios: [PRMAspectRatio] = [],
        supportsSmartFraming: Bool = false
    ) {
        self.uniqueID = uniqueID
        self.deviceType = deviceType
        self.position = position
        self.localizedName = localizedName
        self.minZoomFactor = minZoomFactor
        self.maxZoomFactor = maxZoomFactor
        self.switchOverZoomFactors = switchOverZoomFactors
        self.lenses = lenses
        self.hasTorch = hasTorch
        self.hasFlash = hasFlash
        self.exposureBiasRange = exposureBiasRange
        self.isoRange = isoRange
        self.shutterRange = shutterRange
        self.supportsCustomWhiteBalance = supportsCustomWhiteBalance
        self.supportsSlowMotion = supportsSlowMotion
        self.maxFrameRate = maxFrameRate
        maxPhotoDimensions = maxSupportedPhotoDimensions.map(PRMVideoDimensions.init)
        self.supportsCustomLensPosition = supportsCustomLensPosition
        self.apertureRange = apertureRange
        self.recommendedApertureStops = recommendedApertureStops
        self.supportedExposureSignals = supportedExposureSignals
        self.supportsFocusRectOfInterest = supportsFocusRectOfInterest
        self.supportsExposureRectOfInterest = supportsExposureRectOfInterest
        self.supportsPrimaryConstituentLock = supportsPrimaryConstituentLock
        self.supportsLensSmudgeDetection = supportsLensSmudgeDetection
        self.supportsLowLightVideoNoiseReduction = supportsLowLightVideoNoiseReduction
        self.supportsContinuousAutoFocusTracking = supportsContinuousAutoFocusTracking
        self.supportsCinematicVideo = supportsCinematicVideo
        self.cinematicVideoDeviceType = cinematicVideoDeviceType ?? (supportsCinematicVideo ? deviceType : nil)
        self.cinematicZoomRange = cinematicZoomRange
        self.simulatedApertureRange = simulatedApertureRange
        self.cinematicFrameRateRange = cinematicFrameRateRange
        self.supportedDynamicAspectRatios = supportedDynamicAspectRatios
        self.supportsSmartFraming = supportsSmartFraming
    }

    /// Constructs a snapshot from an `AVCaptureDevice`. Call from session-actor context where
    /// reading the device's mutable properties is safe.
    public init(snapshotting device: AVCaptureDevice) {
        uniqueID = device.uniqueID
        deviceType = device.deviceType
        position = device.position
        localizedName = device.localizedName
        minZoomFactor = device.minAvailableVideoZoomFactor
        maxZoomFactor = device.maxAvailableVideoZoomFactor
        switchOverZoomFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        lenses = device.prm_lenses()
        hasTorch = device.hasTorch
        hasFlash = device.hasFlash
        exposureBiasRange = device.minExposureTargetBias ... device.maxExposureTargetBias
        isoRange = device.activeFormat.minISO ... device.activeFormat.maxISO
        shutterRange = device.prm_shutterSpeedRange()
        supportsCustomWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        supportsSlowMotion = device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
        }
        var maxFPS: Float64 = 0
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
        }
        maxFrameRate = maxFPS
        // Largest landscape photo entry across all formats. Mirrors the scoring used
        // in `PRMCameraSession.applyPreferredPhotoFormatIfNeeded` so UI gating matches
        // the format the session would actually pick.
        var bestPhotoDims: CMVideoDimensions?
        var bestArea: Int64 = 0
        for format in device.formats {
            for dim in format.supportedMaxPhotoDimensions where dim.width >= dim.height {
                let area = Int64(dim.width) * Int64(dim.height)
                if area > bestArea {
                    bestArea = area
                    bestPhotoDims = dim
                }
            }
        }
        maxPhotoDimensions = bestPhotoDims.map(PRMVideoDimensions.init)
        supportsCustomLensPosition = device.isFocusModeSupported(.locked)
            && device.isLockingFocusWithCustomLensPositionSupported

        let format = device.activeFormat
        if #available(iOS 27.0, *) {
            apertureRange = device.prm_lensApertureRange
            recommendedApertureStops = format.recommendedLensApertureStops
            supportedExposureSignals = PRMExposureSignal.set(from: device.supportedExposureSignals)
            supportsPrimaryConstituentLock = device.isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported
            supportsLowLightVideoNoiseReduction = format.isLowLightVideoNoiseReductionSupported
            supportsContinuousAutoFocusTracking = format.isContinuousAutoFocusTrackingSupported
        } else {
            apertureRange = nil
            recommendedApertureStops = []
            supportedExposureSignals = []
            supportsPrimaryConstituentLock = false
            supportsLowLightVideoNoiseReduction = false
            supportsContinuousAutoFocusTracking = false
        }
        if #available(iOS 26.0, *) {
            supportsFocusRectOfInterest = device.isFocusRectOfInterestSupported
            supportsExposureRectOfInterest = device.isExposureRectOfInterestSupported
            supportsLensSmudgeDetection = format.isCameraLensSmudgeDetectionSupported
            // The format `PRMCameraSession` would switch to, so the ranges match what
            // enabling Cinematic Video actually gives. Without one here, the ranges are the
            // camera's that enabling switches to.
            let preferredDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ownCinematicFormat = format.isCinematicVideoCaptureSupported
                ? format
                : AVCaptureDevice.prm_bestCinematicFormat(from: device.formats, preferredDimensions: preferredDimensions)
            supportsCinematicVideo = ownCinematicFormat != nil
            var cinematicFormat = ownCinematicFormat
            if ownCinematicFormat != nil {
                cinematicVideoDeviceType = device.deviceType
            } else {
                let type = Self.cinematicVideoDeviceType(at: device.position)
                cinematicVideoDeviceType = type
                if let type, let other = AVCaptureDevice.default(type, for: .video, position: device.position) {
                    cinematicFormat = AVCaptureDevice.prm_bestCinematicFormat(from: other.formats, preferredDimensions: preferredDimensions)
                }
            }
            if let cinematicFormat {
                let minZoom = cinematicFormat.videoMinZoomFactorForCinematicVideo
                let maxZoom = cinematicFormat.videoMaxZoomFactorForCinematicVideo
                cinematicZoomRange = minZoom <= maxZoom ? minZoom ... maxZoom : nil
                simulatedApertureRange = cinematicFormat.prm_simulatedApertureRange
                cinematicFrameRateRange = cinematicFormat.prm_cinematicFrameRateRange
            } else {
                cinematicZoomRange = nil
                simulatedApertureRange = nil
                cinematicFrameRateRange = nil
            }
            supportedDynamicAspectRatios = format.supportedDynamicAspectRatios.compactMap(PRMAspectRatio.init)
            supportsSmartFraming = format.isSmartFramingSupported && device.smartFramingMonitor != nil
        } else {
            supportsFocusRectOfInterest = false
            supportsExposureRectOfInterest = false
            supportsLensSmudgeDetection = false
            supportsCinematicVideo = false
            cinematicVideoDeviceType = nil
            cinematicZoomRange = nil
            simulatedApertureRange = nil
            cinematicFrameRateRange = nil
            supportedDynamicAspectRatios = []
            supportsSmartFraming = false
        }
    }

    /// Whether *any* discoverable device at `position` supports a format at ≥120 fps.
    ///
    /// Use this to gate UI affordances for slow motion when the currently-active device
    /// might not directly expose ≥120 fps formats — on iPhone 15/16 Pro/Pro Max the
    /// virtual `.builtInTripleCamera`'s `formats` list caps at 60 fps, but the physical
    /// `.builtInWideAngleCamera` (a separately-discoverable device) does support 120/240.
    /// Switch to it via ``PRMCamera/switchDevice(type:position:)`` when entering slo-mo.
    public static func anyDeviceSupportsSlowMotion(at position: AVCaptureDevice.Position) -> Bool {
        SlowMotionCache.supports(at: position)
    }

    /// The camera at `position` that Cinematic Video runs on (iOS 26), or `nil` when none has
    /// a Cinematic Video format (or before iOS 26).
    ///
    /// Apple supports Cinematic Video on the back Dual Wide camera and the front TrueDepth
    /// camera, not the Triple camera Pro iPhones open by default. This checks, in order, the
    /// Dual Wide, TrueDepth, Triple, Dual, wide-angle, ultra-wide and telephoto cameras for a
    /// Cinematic Video format. The answer is cached per position: a camera's formats don't
    /// change at runtime.
    public static func cinematicVideoDeviceType(at position: AVCaptureDevice.Position) -> AVCaptureDevice.DeviceType? {
        CinematicVideoDeviceCache.deviceType(at: position)
    }
}

/// Per-position cache for ``PRMCameraDevice/cinematicVideoDeviceType(at:)``: the discovery
/// walks every format of several cameras.
private enum CinematicVideoDeviceCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var values: [AVCaptureDevice.Position: AVCaptureDevice.DeviceType?] = [:]

    static func deviceType(at position: AVCaptureDevice.Position) -> AVCaptureDevice.DeviceType? {
        if let cached = lock.withLock({ values[position] }) {
            return cached
        }
        let result = discover(at: position)
        lock.withLock { values[position] = result }
        return result
    }

    private static func discover(at position: AVCaptureDevice.Position) -> AVCaptureDevice.DeviceType? {
        guard #available(iOS 26.0, *) else { return nil }
        let preference: [AVCaptureDevice.DeviceType] = [
            .builtInDualWideCamera,
            .builtInTrueDepthCamera,
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
        ]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: preference, mediaType: .video, position: position).devices
        return preference.first { type in
            devices.contains { $0.deviceType == type && $0.formats.contains(where: \.isCinematicVideoCaptureSupported) }
        }
    }
}

/// Per-position cache for the slow-motion discovery result. The device list itself
/// is hardware — it doesn't change at runtime — so the answer is constant per
/// `(deviceTypes, mediaType, position)` triple. Repeatedly building a
/// `DiscoverySession` (e.g. from a settings-drawer telemetry tick that fires every
/// 500 ms) wastes allocations and CPU; cache once per position.
private enum SlowMotionCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var values: [AVCaptureDevice.Position: Bool] = [:]

    static func supports(at position: AVCaptureDevice.Position) -> Bool {
        lock.lock()
        if let cached = values[position] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )
        let result = discovery.devices.contains { device in
            device.formats.contains { format in
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
            }
        }

        lock.lock()
        values[position] = result
        lock.unlock()
        return result
    }
}
