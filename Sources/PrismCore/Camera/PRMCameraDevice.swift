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

    /// Whether the device supports locking white balance with custom temperature/tint.
    public let supportsCustomWhiteBalance: Bool

    /// Whether the device supports any format at ≥120 fps (slow motion).
    public let supportsSlowMotion: Bool

    /// Maximum supported frame rate across all formats.
    public let maxFrameRate: Float64

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
        supportsCustomWhiteBalance: Bool,
        supportsSlowMotion: Bool,
        maxFrameRate: Float64
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
        self.supportsCustomWhiteBalance = supportsCustomWhiteBalance
        self.supportsSlowMotion = supportsSlowMotion
        self.maxFrameRate = maxFrameRate
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
    }

    /// Whether *any* discoverable device at `position` supports a format at ≥120 fps.
    ///
    /// Use this to gate UI affordances for slow motion when the currently-active device
    /// might not directly expose ≥120 fps formats — on iPhone 15/16 Pro/Pro Max the
    /// virtual `.builtInTripleCamera`'s `formats` list caps at 60 fps, but the physical
    /// `.builtInWideAngleCamera` (a separately-discoverable device) does support 120/240.
    /// Switch to it via ``PRMCamera/switchDevice(type:position:)`` when entering slo-mo.
    public static func anyDeviceSupportsSlowMotion(at position: AVCaptureDevice.Position) -> Bool {
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
        return discovery.devices.contains { device in
            device.formats.contains { format in
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
            }
        }
    }
}
