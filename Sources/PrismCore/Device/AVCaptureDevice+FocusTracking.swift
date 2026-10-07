import AVFoundation

// iOS 27 continuous autofocus subject tracking. Tracking only reports progress (and
// `isContinuousAutoFocusTrackingSubjectAcquired` only turns true) when the device feeds an
// `AVCaptureMetadataOutput` subscribed to `.focusTrackedObject`. `PRMCameraSession` wires that
// up in `setContinuousAutoFocusTrackingEnabled(_:)`; call these helpers directly only if you
// manage the metadata output yourself.

public extension AVCaptureDevice {
    /// Whether the active format supports continuous autofocus tracking (iOS 27).
    var prm_isContinuousAutoFocusTrackingSupported: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return activeFormat.isContinuousAutoFocusTrackingSupported
    }

    /// Whether tracking is enabled (iOS 27). `false` before that.
    var prm_isContinuousAutoFocusTrackingEnabled: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return isContinuousAutoFocusTrackingEnabled
    }

    /// Whether a subject is being tracked right now (iOS 27). `false` before that.
    var prm_isContinuousAutoFocusTrackingSubjectAcquired: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return isContinuousAutoFocusTrackingSubjectAcquired
    }

    /// Current tracking lens-position bias (iOS 27). `0` before that.
    var prm_continuousAutoFocusTrackingBias: Float {
        guard #available(iOS 27.0, *) else { return 0 }
        return continuousAutoFocusTrackingLensPositionBias
    }

    /// Turns continuous autofocus tracking on or off (iOS 27).
    ///
    /// On: tracking engages the next time focus mode is set to `.continuousAutoFocus`, and
    /// follows the subject at `focusPointOfInterest`. A tap-to-focus with
    /// `.continuousAutoFocus` therefore becomes tap-to-track. If the device is already in
    /// continuous AF, the mode is re-set here so tracking starts at the current point.
    ///
    /// Off: follows the SDK's recipe (reset the bias, disable, re-set `.continuousAutoFocus`)
    /// so the tracker actually lets go.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` before iOS 27 or when the
    ///   active format doesn't support tracking. AVFoundation also refuses while Cinematic
    ///   Video is enabled; the session layer guards that.
    func prm_setContinuousAutoFocusTracking(_ enabled: Bool) throws {
        guard #available(iOS 27.0, *) else {
            throw PRMSessionError.unsupportedConfiguration("Continuous autofocus tracking requires iOS 27")
        }
        if enabled, !activeFormat.isContinuousAutoFocusTrackingSupported {
            throw PRMSessionError.unsupportedConfiguration("The active format doesn't support continuous autofocus tracking")
        }
        try prm_withConfigurationLock {
            if enabled {
                isContinuousAutoFocusTrackingEnabled = true
                // Tracking would otherwise be retargeted to the frame center every time the
                // subject-area-change handler re-centers focus.
                isSubjectAreaChangeMonitoringEnabled = false
            } else {
                guard isContinuousAutoFocusTrackingEnabled else { return }
                continuousAutoFocusTrackingLensPositionBias = 0
                isContinuousAutoFocusTrackingEnabled = false
            }
            if focusMode == .continuousAutoFocus {
                focusMode = .continuousAutoFocus
            }
        }
    }

    /// Biases tracked focus toward the nearest (-1) or farthest (1) part of the subject
    /// (iOS 27). Clamped to `-1...1`.
    ///
    /// The bias applies on the next `.continuousAutoFocus` mode set, which also re-acquires
    /// the subject at `focusPointOfInterest`. AVFoundation stops updating that point while it
    /// tracks, so pass `retargetingAt` (e.g. the center of the last
    /// ``PRMDetectedObject/Kind/focusTracked`` bounds) to keep following the same subject.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` unless tracking is enabled.
    func prm_setContinuousAutoFocusTrackingBias(_ bias: Float, retargetingAt devicePoint: CGPoint? = nil) throws {
        guard #available(iOS 27.0, *), isContinuousAutoFocusTrackingEnabled else {
            throw PRMSessionError.unsupportedConfiguration("Enable continuous autofocus tracking before setting its bias")
        }
        try prm_withConfigurationLock {
            continuousAutoFocusTrackingLensPositionBias = Self.prm_clampedTrackingBias(bias)
            if let devicePoint, isFocusPointOfInterestSupported {
                focusPointOfInterest = Self.prm_clampedUnitPoint(devicePoint)
            }
            focusMode = .continuousAutoFocus
        }
    }
}

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// Clamps a tracking bias into `-1...1`; non-finite values become `0`.
    static func prm_clampedTrackingBias(_ bias: Float) -> Float {
        guard bias.isFinite else { return 0 }
        return min(max(bias, -1), 1)
    }
}
