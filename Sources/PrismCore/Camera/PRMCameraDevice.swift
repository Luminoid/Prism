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
    public let maxSupportedPhotoDimensions: CMVideoDimensions?

    /// Whether the device supports `setFocusModeLocked(lensPosition:)`. Virtual devices
    /// (`triple`, `dual`, `dualWide`) report `isFocusModeSupported(.locked) == true` but
    /// throw `NSInvalidArgumentException` at the setter call (newer iOS releases enforce
    /// `isLockingFocusWithCustomLensPositionSupported` as a separate gate). Gate manual-
    /// focus UI on this flag and require a physical-device swap when false.
    public let supportsCustomLensPosition: Bool

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
        supportsCustomLensPosition: Bool = true
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
        self.maxSupportedPhotoDimensions = maxSupportedPhotoDimensions
        self.supportsCustomLensPosition = supportsCustomLensPosition
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
        maxSupportedPhotoDimensions = bestPhotoDims
        supportsCustomLensPosition = device.isFocusModeSupported(.locked)
            && device.isLockingFocusWithCustomLensPositionSupported
    }

    /// Whether *any* discoverable device at `position` supports a format at ≥120 fps.
    ///
    /// Use this to gate UI affordances for slow motion when the currently-active device
    /// might not directly expose ≥120 fps formats — on iPhone 15/16 Pro/Pro Max the
    /// virtual `.builtInTripleCamera`'s `formats` list caps at 60 fps, but the physical
    /// `.builtInWideAngleCamera` (a separately-discoverable device) does support 120/240.
    /// Switch to it via ``PRMCamera/switchDevice(type:position:)`` when entering slo-mo.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uniqueID == rhs.uniqueID
            && lhs.deviceType == rhs.deviceType
            && lhs.position == rhs.position
            && lhs.localizedName == rhs.localizedName
            && lhs.minZoomFactor == rhs.minZoomFactor
            && lhs.maxZoomFactor == rhs.maxZoomFactor
            && lhs.switchOverZoomFactors == rhs.switchOverZoomFactors
            && lhs.lenses == rhs.lenses
            && lhs.hasTorch == rhs.hasTorch
            && lhs.hasFlash == rhs.hasFlash
            && lhs.exposureBiasRange == rhs.exposureBiasRange
            && lhs.isoRange == rhs.isoRange
            && lhs.shutterRange == rhs.shutterRange
            && lhs.supportsCustomWhiteBalance == rhs.supportsCustomWhiteBalance
            && lhs.supportsSlowMotion == rhs.supportsSlowMotion
            && lhs.maxFrameRate == rhs.maxFrameRate
            && lhs.maxSupportedPhotoDimensions?.width == rhs.maxSupportedPhotoDimensions?.width
            && lhs.maxSupportedPhotoDimensions?.height == rhs.maxSupportedPhotoDimensions?.height
            && lhs.supportsCustomLensPosition == rhs.supportsCustomLensPosition
    }

    public static func anyDeviceSupportsSlowMotion(at position: AVCaptureDevice.Position) -> Bool {
        SlowMotionCache.supports(at: position)
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
