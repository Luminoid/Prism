import AVFoundation

public extension AVCaptureDevice {
    /// Runs `body` inside a paired `lockForConfiguration()` / `unlockForConfiguration()`
    /// scope, guaranteeing the unlock fires even if `body` throws or returns early. Folds
    /// the boilerplate that every manual setter (`+Exposure`, `+WhiteBalance`, `+ISO`,
    /// `+Lens`, `+FrameRate`, `+Zoom`, `+Torch`, `+HDR`) used to repeat inline.
    ///
    /// Forwards exceptions from `lockForConfiguration()` (and from `body`) untouched —
    /// AVFoundation's lock error has a specific reason code callers may want to inspect.
    func withConfigurationLock<T>(_ body: () throws -> T) throws -> T {
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        return try body()
    }

    /// `true` for `.builtInTripleCamera`, `.builtInDualCamera`, `.builtInDualWideCamera`
    /// (and any future virtual multi-camera AVFoundation may add).
    ///
    /// Why this matters: virtual devices aggregate multiple constituent physical cameras
    /// whose auto-AE / auto-AWB systems keep re-asserting themselves. Per Apple's
    /// white-balance docs: *"exposure duration, ISO, aperture, white balance gains, or
    /// lens position may change when the device switches from one camera to the other."*
    /// User-visible symptom: `setExposureModeCustom` / `setWhiteBalanceModeLocked`
    /// "return success" but the slider drag doesn't change preview color, ISO/shutter
    /// labels update but the saved photo's EXIF shows continuous-auto values. The
    /// canonical workaround is to switch to the physical `.builtInWideAngleCamera`
    /// before issuing manual controls.
    ///
    /// `virtualDeviceSwitchOverVideoZoomFactors` is the AVFoundation-documented signal
    /// — empty on single-lens devices, populated with the zoom factors at which the
    /// virtual device transitions between its constituent cameras.
    var prm_isVirtualMultiCameraDevice: Bool {
        !virtualDeviceSwitchOverVideoZoomFactors.isEmpty
    }
}
