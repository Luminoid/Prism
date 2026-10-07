import AVFoundation

public extension AVCaptureDevice {
    /// Sets video HDR on the active format. Turning it off (or back to auto) where the
    /// format has no HDR is a no-op.
    ///
    /// - Parameter enabled: When `nil`, returns control to the system (auto). When `true` or
    ///   `false`, locks HDR on or off.
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when turning HDR on for a
    ///   format without it, or AVFoundation's lock error.
    func prm_setVideoHDR(_ enabled: Bool?) throws {
        guard activeFormat.isVideoHDRSupported else {
            if enabled == true {
                throw PRMSessionError.unsupportedConfiguration("The active format has no video HDR")
            }
            return
        }
        // The app now owns this setting; manual exposure won't hand it back on its own.
        prm_clearDisabledByPrism(.videoHDR)
        try prm_withConfigurationLock {
            if let enabled {
                automaticallyAdjustsVideoHDREnabled = false
                isVideoHDREnabled = enabled
            } else {
                automaticallyAdjustsVideoHDREnabled = true
            }
        }
    }

    /// Enables or disables low-light boost. Mutually exclusive with custom exposure modes.
    /// Disabling it on a device without it is a no-op.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when enabling it on a
    ///   device without low-light boost, or AVFoundation's lock error.
    func prm_setLowLightBoost(_ enabled: Bool) throws {
        guard isLowLightBoostSupported else {
            if enabled {
                throw PRMSessionError.unsupportedConfiguration("\(localizedName) has no low-light boost")
            }
            return
        }
        try prm_withConfigurationLock {
            automaticallyEnablesLowLightBoostWhenAvailable = enabled
        }
    }

    /// Whether low-light boost is currently active on the device.
    var prm_isLowLightBoostActive: Bool {
        isLowLightBoostEnabled
    }
}
