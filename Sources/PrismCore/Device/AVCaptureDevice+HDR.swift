import AVFoundation

public extension AVCaptureDevice {
    /// Sets video HDR on the active format if supported. No-op otherwise.
    ///
    /// - Parameter enabled: When `nil`, returns control to the system (auto). When `true` or
    ///   `false`, locks HDR on or off.
    func prm_setVideoHDR(_ enabled: Bool?) throws {
        guard activeFormat.isVideoHDRSupported else { return }
        try withConfigurationLock {
            if let enabled {
                automaticallyAdjustsVideoHDREnabled = false
                isVideoHDREnabled = enabled
            } else {
                automaticallyAdjustsVideoHDREnabled = true
            }
        }
    }

    /// Enables or disables low-light boost if the device supports it.
    /// Mutually exclusive with custom exposure modes.
    func prm_setLowLightBoost(_ enabled: Bool) throws {
        guard isLowLightBoostSupported else { return }
        try withConfigurationLock {
            automaticallyEnablesLowLightBoostWhenAvailable = enabled
        }
    }

    /// Whether low-light boost is currently active on the device.
    var prm_isLowLightBoostActive: Bool {
        isLowLightBoostEnabled
    }
}
