@preconcurrency import AVFoundation

// MARK: - Device controls that check and change in one actor turn

//
// Zoom, frame rate and depth format changes depend on session conditions (Cinematic Video,
// a recording, the attached movie output). Each method below checks them and mutates in the
// same synchronous actor turn, so a concurrent toggle can't slip in between. `PRMCamera`
// calls these rather than doing the work inside `PRMCameraActor.run { }`, whose body isn't
// isolated to the actor (every `await` in it is its own hop).

public extension PRMCameraSession {
    // MARK: Zoom

    /// Sets the raw zoom factor, clamped to the device range and, while Cinematic Video is
    /// enabled, to its narrower zoom range. No-op without a device.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` for a non-finite factor, or
    ///   AVFoundation's lock error.
    func setZoom(_ factor: CGFloat) throws {
        guard let device = videoDevice else { return }
        try refuseDuringExclusiveCapture("Zooming")
        try device.prm_setZoom(cinematicClampedZoom(factor))
    }

    /// Starts a smooth zoom ramp to `factor` (clamped as in ``setZoom(_:)``).
    func rampZoom(to factor: CGFloat, rate: Float = 1.0) throws {
        guard let device = videoDevice else { return }
        try refuseDuringExclusiveCapture("Zooming")
        try device.prm_rampZoom(to: cinematicClampedZoom(factor), rate: rate)
    }

    // MARK: Frame rate

    /// Sets the frame rate in one begin/commit: switches the preset to `.inputPriority` when
    /// the format may change (named presets reject custom formats and silently cut the movie
    /// output's video connection), picks a format that delivers `fps` if needed, re-applies
    /// the pixel format, photo ceiling and feature intents for the new format, and rebuilds
    /// an attached movie output against it. A recorder that starts right after this returns
    /// finds the new movie output; it can't land between the detach and the re-attach.
    ///
    /// While Cinematic Video is enabled its format is fixed: only rates inside its frame-rate
    /// range apply (as frame durations on that format).
    ///
    /// - Returns: What was applied, or `nil` when no format delivers `fps` (or format changes
    ///   weren't allowed and the current one doesn't).
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while recording, or under
    ///   Cinematic Video for a rate outside its range; AVFoundation's lock error.
    @discardableResult
    func setFrameRate(_ fps: Float64, allowFormatChange: Bool = true) throws -> AVCaptureDevice.PRMFrameRateChange? {
        guard let device = videoDevice else { return nil }
        try refuseWhileBusy("Changing the frame rate")
        if isCinematicVideoCaptureActive {
            guard let range = device.activeFormat.prm_cinematicFrameRateRange, range.contains(fps) else {
                throw PRMSessionError.unsupportedConfiguration("\(Int(fps)) fps is outside Cinematic Video's frame-rate range")
            }
            return try device.prm_setFrameRate(fps, allowFormatChange: false)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Relax to input-priority BEFORE the format swap. Skip the preset write if we're
        // already there to avoid log noise and AVF re-validation churn.
        if allowFormatChange, session.sessionPreset != .inputPriority {
            if session.canSetSessionPreset(.inputPriority) {
                PRMLog.notice(
                    .session,
                    "setFrameRate: switching sessionPreset \(session.sessionPreset.prm_logName) → InputPriority to allow custom format"
                )
                session.sessionPreset = .inputPriority
            } else {
                PRMLog.warning(
                    .session,
                    "setFrameRate: session does not support .inputPriority preset; format swap may invalidate AVCaptureMovieFileOutput connection"
                )
            }
        }
        let change = try device.prm_setFrameRate(fps, allowFormatChange: allowFormatChange)
        guard change?.formatChanged == true else { return change }

        refreshVideoDataOutputPixelFormat()
        refreshOutputMaxPhotoDimensions()
        applyFeatureIntents()
        // Even with the `.inputPriority` preset, AVFoundation tears down the movie output's
        // video connection during the format swap and the same instance doesn't always get
        // an active one back. A fresh output added in this same commit is built against the
        // new format. Live Photo stays off throughout (one final state, no toggle pair).
        if movieFileOutput != nil {
            PRMLog.notice(.session, "setFrameRate: format changed — re-attaching movieFileOutput against new active format")
            try applyMovieFileOutputAttached(false, targetLivePhoto: false)
            try applyMovieFileOutputAttached(true)
        }
        return change
    }

    /// Clears the custom frame rate and restores the preset ``configure(_:)`` used, in one
    /// begin/commit. Leaving the session in `.inputPriority` for a photo workflow can leave
    /// the photo output without an active video connection, so the next capture would raise.
    /// The restore is best-effort: a preset the current format can't take is left alone.
    ///
    /// While Cinematic Video is enabled only the frame durations are cleared; its format stays.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while recording;
    ///   AVFoundation's lock error.
    func resetFrameRate() throws {
        guard let device = videoDevice else { return }
        if isCinematicVideoCaptureActive {
            try device.prm_resetFrameRate()
            return
        }
        try refuseWhileBusy("Resetting the frame rate")
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let originalPreset = configuredSessionPreset, session.sessionPreset != originalPreset {
            if session.canSetSessionPreset(originalPreset) {
                PRMLog.notice(
                    .session,
                    "resetFrameRate: restoring sessionPreset \(session.sessionPreset.prm_logName) → \(originalPreset.prm_logName)"
                )
                session.sessionPreset = originalPreset
            } else {
                PRMLog.warning(
                    .session,
                    "resetFrameRate: cannot restore sessionPreset \(originalPreset.prm_logName) on current device — staying on \(session.sessionPreset.prm_logName)"
                )
            }
        }
        try device.prm_resetFrameRate()
        // The preset restore can replace the active format.
        refreshVideoDataOutputPixelFormat()
        refreshOutputMaxPhotoDimensions()
        applyFeatureIntents()
    }

    // MARK: Depth format

    /// Switches `activeFormat` and `activeDepthDataFormat` to a depth-capable pair and makes
    /// the photo output re-validate its depth and portrait-matte delivery against it, in one
    /// begin/commit. Returns whether a depth format is now active.
    ///
    /// The photo output validates its delivery flags against the active format at commit
    /// time; without the toggle-off/toggle-on below the flags stay "enabled" but depth
    /// captures arrive with an internally null `depthDataMap`.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while Cinematic Video is
    ///   enabled or while recording; AVFoundation's lock error.
    @discardableResult
    func enableDepthFormat() throws -> Bool {
        if isCinematicVideoCaptureActive {
            throw PRMSessionError.unsupportedConfiguration("Switching to a depth format isn't available while Cinematic Video is enabled")
        }
        try refuseWhileBusy("Switching to a depth format")
        guard let device = videoDevice else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard try device.prm_enableDepthFormat() else { return false }
        if let photoOutput {
            if photoOutput.isDepthDataDeliverySupported {
                photoOutput.isDepthDataDeliveryEnabled = false
                photoOutput.isDepthDataDeliveryEnabled = true
            }
            if photoOutput.isPortraitEffectsMatteDeliverySupported {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
            }
        }
        applyFeatureIntents()
        return true
    }
}
