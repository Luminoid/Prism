@preconcurrency import AVFoundation

// MARK: - Cinematic Video (iOS 26)

//
// Cinematic Video is a property of the device *input*, so it dies with every new
// `AVCaptureDeviceInput`. It isn't re-applied inside `swapInput` (which would snapshot a
// cinematic format as the new baseline); `PRMCamera.switchCamera` / `switchDevice` call
// `reapplyCinematicVideoCaptureIfNeeded()` after the swap settles. Direct users of
// `PRMCameraSession` must do the same.
//
// Enabling can take two configuration commits: the input may only report Cinematic support
// once a format change has been committed. The second commit waits for the first rebuild to
// settle (`awaitPhotoOutputReady`), so the rebuilds run one at a time. Don't wrap these calls
// in your own begin/commit: nested pairs only apply at the outermost commit, so the input
// would never see the new format and enabling would fail.
//
// While it's enabled, AVFoundation pins focus to continuous AF and raises
// `NSInvalidArgumentException` on any focus-mode change. `PRMCamera` checks the flag in the
// same actor turn as every focus write (`withVideoDevice(_:)`); raw `prm_` focus helpers
// don't.

public extension PRMCameraSession {
    // MARK: State

    /// Whether Cinematic Video capture is enabled on the current video input.
    var isCinematicVideoCaptureActive: Bool {
        guard #available(iOS 26.0, *), let input = videoDeviceInput else { return false }
        return input.isCinematicVideoCaptureEnabled
    }

    /// Current Cinematic Video simulated aperture, or `0` when Cinematic Video is off.
    var cinematicSimulatedAperture: Float {
        guard #available(iOS 26.0, *), let input = videoDeviceInput, input.isCinematicVideoCaptureEnabled else { return 0 }
        return input.simulatedAperture
    }

    /// Whether the movie output records Cinematic Video metadata (iOS 27).
    var isCinematicVideoMetadataCaptureEnabled: Bool {
        guard #available(iOS 27.0, *), let output = movieFileOutput else { return false }
        return output.isCinematicVideoMetadataCaptureEnabled
    }

    /// Runs `body` against the current video device in one actor turn, passing whether
    /// Cinematic Video is enabled. The flag and the mutation can't be separated by a
    /// concurrent Cinematic toggle, which matters because AVFoundation raises (uncatchably)
    /// on a focus-mode change while Cinematic Video is on. Returns `nil` without a device.
    func withVideoDevice<T: Sendable>(
        _ body: @Sendable (_ device: AVCaptureDevice, _ cinematicVideoActive: Bool) throws -> T
    ) rethrows -> T? {
        guard let device = videoDevice else { return nil }
        return try body(device, isCinematicVideoCaptureActive)
    }

    // MARK: Enable / disable

    /// Turns Cinematic Video capture on or off (iOS 26).
    ///
    /// Enabling switches to a Cinematic-capable format if needed, turns off photo depth and
    /// portrait-matte delivery (Cinematic Video runs its own depth pipeline), resets the
    /// frame rate, clamps zoom to the cinematic range, turns subject tracking off, attaches
    /// the movie output (Live Photo off) and the metadata output with the types Cinematic
    /// Video requires, and re-applies the last simulated aperture. Disabling restores the
    /// configure-time format, preset and photo delivery flags; the movie output stays
    /// attached.
    ///
    /// - Parameters:
    ///   - enabled: Turn Cinematic Video on or off.
    ///   - targetPhotoOutputAttached: Attach (`true`) or detach (`false`) the photo
    ///     output in the same commit. Detaching is the remedy if the session hits
    ///     AVError -11872 (ISP bandwidth). `nil` leaves it as is when enabling, and
    ///     re-attaches it per the configuration when disabling.
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` before iOS 26, while
    ///   recording, when a depth data output is attached, or when the device has no
    ///   Cinematic Video format. A failed enable leaves the format, preset and subject
    ///   tracking as they were. ``PRMSessionError/cancelled`` when a later toggle or camera
    ///   switch overtook the enable while it waited for the first rebuild.
    func setCinematicVideoCaptureEnabled(_ enabled: Bool, targetPhotoOutputAttached: Bool? = nil) async throws {
        PRMLog.debug(.session, "setCinematicVideoCaptureEnabled(\(enabled))")
        defer { PRMLog.debug(.session, "setCinematicVideoCaptureEnabled done: hardwareCost=\(session.hardwareCost)") }
        guard #available(iOS 26.0, *) else {
            wantsCinematicVideo = false
            throw PRMSessionError.unsupportedConfiguration("Cinematic Video requires iOS 26")
        }
        try refuseWhileBusy("Toggling Cinematic Video")
        cinematicGeneration += 1
        guard enabled else {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            disableCinematicVideo(targetPhotoOutputAttached: targetPhotoOutputAttached)
            return
        }
        try await enableCinematicVideoInPhases(targetPhotoOutputAttached: targetPhotoOutputAttached, attachMovieOutput: true)
    }

    /// Re-enables Cinematic Video on the current input when it was on before a camera
    /// switch. The movie output is left as the app arranged it. If the new device can't do
    /// Cinematic Video, the intent is dropped and the error rethrown.
    func reapplyCinematicVideoCaptureIfNeeded() async throws {
        guard wantsCinematicVideo, !isCinematicVideoCaptureActive else { return }
        guard #available(iOS 26.0, *) else {
            wantsCinematicVideo = false
            return
        }
        try await enableCinematicVideoInPhases(targetPhotoOutputAttached: nil, attachMovieOutput: false)
    }

    // MARK: Simulated aperture

    /// Sets the Cinematic Video depth-of-field 𝑓-number. Returns the value applied after
    /// clamping to the format's range. Kept across camera switches.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` unless Cinematic Video is
    ///   enabled, not recording, and the format allows changing the aperture.
    @discardableResult
    func setCinematicSimulatedAperture(_ aperture: Float) throws -> Float {
        guard #available(iOS 26.0, *), let input = videoDeviceInput, input.isCinematicVideoCaptureEnabled,
              let device = videoDevice
        else {
            throw PRMSessionError.unsupportedConfiguration("Enable Cinematic Video before setting its aperture")
        }
        try refuseWhileBusy("Changing the Cinematic Video aperture")
        guard let range = device.activeFormat.prm_simulatedApertureRange else {
            throw PRMSessionError.unsupportedConfiguration("This format's simulated aperture can't change")
        }
        let clamped = min(max(aperture, range.lowerBound), range.upperBound)
        cinematicSimulatedApertureIntent = clamped
        input.simulatedAperture = clamped
        return clamped
    }

    // MARK: Metadata capture (iOS 27)

    /// Chooses whether the movie output records Cinematic Video metadata for post-capture
    /// focus editing (iOS 27). Re-applied whenever the movie output or format changes.
    func setCinematicMetadataCapture(_ policy: PRMCinematicMetadataCapture) {
        cinematicMetadataCapture = policy
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyCinematicMetadataCapturePolicy()
    }
}

// MARK: - Internals

extension PRMCameraSession {
    /// What an enable attempt may change, so a failure can put it back exactly.
    private struct CinematicRollback {
        let format: AVCaptureDevice.Format?
        let preset: AVCaptureSession.Preset
        let depthDelivery: Bool
        let matteDelivery: Bool
        let wantsTracking: Bool
    }

    private func cinematicRollbackSnapshot() -> CinematicRollback {
        CinematicRollback(
            format: videoDevice?.activeFormat,
            preset: session.sessionPreset,
            depthDelivery: photoOutput?.isDepthDataDeliveryEnabled ?? false,
            matteDelivery: photoOutput?.isPortraitEffectsMatteDeliveryEnabled ?? false,
            wantsTracking: wantsContinuousAutoFocusTracking
        )
    }

    /// Enable in up to two commits, waiting for the first rebuild to settle before the
    /// second. Rolls back what the attempt changed on failure. The actor can run other work
    /// during the wait; when a Cinematic toggle or camera switch ran in between (the
    /// generation moved or the input changed), this attempt stops with
    /// ``PRMSessionError/cancelled`` and leaves the state to the newer operation.
    @available(iOS 26.0, *)
    private func enableCinematicVideoInPhases(targetPhotoOutputAttached: Bool?, attachMovieOutput: Bool) async throws {
        let rollback = cinematicRollbackSnapshot()
        let generation = cinematicGeneration
        let input = videoDeviceInput
        session.beginConfiguration()
        let finished: Bool
        do {
            finished = try enableCinematicVideo(targetPhotoOutputAttached: targetPhotoOutputAttached, attachMovieOutput: attachMovieOutput)
        } catch {
            rollBackCinematicAttempt(rollback)
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        if finished { return }

        // The input reports Cinematic support only once the format change is committed.
        _ = await awaitPhotoOutputReady()
        guard cinematicGeneration == generation, videoDeviceInput === input else {
            PRMLog.notice(.session, "Cinematic Video enable overtaken by a later toggle or camera switch")
            throw PRMSessionError.cancelled
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            guard try enableCinematicVideo(targetPhotoOutputAttached: targetPhotoOutputAttached, attachMovieOutput: attachMovieOutput) else {
                throw PRMSessionError.unsupportedConfiguration("The video input doesn't support Cinematic Video in this configuration")
            }
        } catch {
            rollBackCinematicAttempt(rollback)
            throw error
        }
    }

    /// Enables Cinematic Video during `configure(_:)`, inside its open begin/commit. The
    /// session isn't running yet in the usual flow, so a second commit needs no readiness
    /// wait. Logs and drops the intent on failure.
    func enableCinematicVideoDuringConfigure() {
        guard #available(iOS 26.0, *) else {
            wantsCinematicVideo = false
            return
        }
        let rollback = cinematicRollbackSnapshot()
        do {
            if try !enableCinematicVideo(targetPhotoOutputAttached: nil, attachMovieOutput: true) {
                session.commitConfiguration()
                session.beginConfiguration()
                guard try enableCinematicVideo(targetPhotoOutputAttached: nil, attachMovieOutput: true) else {
                    throw PRMSessionError.unsupportedConfiguration("The video input doesn't support Cinematic Video in this configuration")
                }
            }
        } catch {
            rollBackCinematicAttempt(rollback)
            PRMLog.warning(.session, "configure: Cinematic Video requested but unavailable", error: error)
        }
    }

    /// One enable pass inside an open begin/commit. Returns `false` when the input doesn't
    /// (yet) report Cinematic Video support after a format change, so the caller can commit
    /// and run another pass.
    @available(iOS 26.0, *)
    private func enableCinematicVideo(targetPhotoOutputAttached: Bool?, attachMovieOutput: Bool) throws -> Bool {
        guard let input = videoDeviceInput, let device = videoDevice else {
            throw PRMSessionError.unsupportedConfiguration("No video input")
        }
        if session.outputs.contains(where: { $0 is AVCaptureDepthDataOutput }) {
            throw PRMSessionError.unsupportedConfiguration("Cinematic Video can't run alongside a depth data output")
        }
        wantsCinematicVideo = true
        // Cinematic Video owns focus; tracking can't run with it and shouldn't come back on
        // its own when Cinematic Video is turned off.
        wantsContinuousAutoFocusTracking = false

        if !device.activeFormat.isCinematicVideoCaptureSupported {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            guard let format = AVCaptureDevice.prm_bestCinematicFormat(from: device.formats, preferredDimensions: dims) else {
                throw PRMSessionError.unsupportedConfiguration("\(device.localizedName) has no Cinematic Video format")
            }
            if session.sessionPreset != .inputPriority, session.canSetSessionPreset(.inputPriority) {
                session.sessionPreset = .inputPriority
            }
            disableCinematicIncompatiblePhotoDelivery()
            try device.prm_withConfigurationLock {
                device.activeFormat = format
            }
            refreshVideoDataOutputPixelFormat()
            refreshOutputMaxPhotoDimensions()
        }
        guard input.isCinematicVideoCaptureSupported else {
            // This commit still changed the format; keep the format-dependent features in
            // step until the next pass enables Cinematic Video.
            applyFeatureIntents()
            return false
        }

        let format = device.activeFormat
        disableCinematicIncompatiblePhotoDelivery()
        PRMLog.bestEffort(.session, "Cinematic Video: resetFrameRate") { try device.prm_resetFrameRate() }
        let zoom = Self.clampedZoom(
            device.videoZoomFactor,
            min: format.videoMinZoomFactorForCinematicVideo,
            max: format.videoMaxZoomFactorForCinematicVideo
        )
        if zoom != device.videoZoomFactor {
            PRMLog.bestEffort(.session, "Cinematic Video: clamp zoom") {
                try device.prm_withConfigurationLock { device.videoZoomFactor = zoom }
            }
        }
        if device.prm_isContinuousAutoFocusTrackingEnabled {
            PRMLog.bestEffort(.session, "Cinematic Video: stop AF tracking") { try device.prm_setContinuousAutoFocusTracking(false) }
        }
        if attachMovieOutput {
            try applyMovieFileOutputAttached(true, targetLivePhoto: false)
        }
        if let targetPhotoOutputAttached {
            try applyPhotoOutputAttached(targetPhotoOutputAttached)
        }

        input.isCinematicVideoCaptureEnabled = true
        if let aperture = cinematicSimulatedApertureIntent, let range = format.prm_simulatedApertureRange {
            input.simulatedAperture = min(max(aperture, range.lowerBound), range.upperBound)
        }
        // Includes the metadata output (Cinematic's required types) and the iOS 27 metadata
        // capture policy.
        applyFeatureIntents()
        return true
    }

    @available(iOS 26.0, *)
    private func disableCinematicVideo(targetPhotoOutputAttached: Bool?) {
        wantsCinematicVideo = false
        if let input = videoDeviceInput, input.isCinematicVideoCaptureEnabled {
            input.isCinematicVideoCaptureEnabled = false
        }
        if let preset = configuredSessionPreset, session.sessionPreset != preset, session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        if let baseline = baselineActiveFormat, videoDevice?.activeFormat !== baseline {
            restoreBaselineFormatInOpenConfiguration(baseline)
        }
        // The baseline restore covers this after a format change; when Cinematic Video ran on
        // the baseline format itself, the depth / matte flags it turned off come back here.
        applyAuxiliaryPhotoOutputFlags(highRes: false)
        refreshOutputMaxPhotoDimensions()
        let reattachPhoto = targetPhotoOutputAttached ?? (configuration?.includesPhotoOutput == true)
        if reattachPhoto != (photoOutput != nil) {
            PRMLog.bestEffort(.session, "Cinematic Video off: setPhotoOutputAttached(\(reattachPhoto))") {
                try applyPhotoOutputAttached(reattachPhoto)
            }
        }
        applyFeatureIntents()
    }

    /// Photo depth and portrait-matte delivery compete with Cinematic Video's own depth
    /// pipeline; turn them off before the format or flag changes.
    func disableCinematicIncompatiblePhotoDelivery() {
        guard let output = photoOutput else { return }
        if output.isDepthDataDeliveryEnabled {
            output.isDepthDataDeliveryEnabled = false
        }
        if output.isPortraitEffectsMatteDeliveryEnabled {
            output.isPortraitEffectsMatteDeliveryEnabled = false
        }
    }

    /// Undoes an enable attempt: the input flag, preset, format and photo delivery flags go
    /// back to the snapshot. Outputs the app arranged (a detached photo output, an attached
    /// movie output) stay as they are. Call inside an open begin/commit.
    private func rollBackCinematicAttempt(_ rollback: CinematicRollback) {
        wantsCinematicVideo = false
        // Enabling turned the tracking intent off up front; a failed attempt gives it back
        // (`applyFeatureIntents()` below re-applies it to the device).
        wantsContinuousAutoFocusTracking = rollback.wantsTracking
        if #available(iOS 26.0, *), let input = videoDeviceInput, input.isCinematicVideoCaptureEnabled {
            input.isCinematicVideoCaptureEnabled = false
        }
        if session.sessionPreset != rollback.preset, session.canSetSessionPreset(rollback.preset) {
            session.sessionPreset = rollback.preset
        }
        if let format = rollback.format, let device = videoDevice, device.activeFormat !== format,
           device.formats.contains(where: { $0 === format }) {
            PRMLog.bestEffort(.session, "Cinematic Video rollback: restore activeFormat") {
                try device.prm_withConfigurationLock { device.activeFormat = format }
            }
            refreshVideoDataOutputPixelFormat()
        }
        if let output = photoOutput {
            if output.isDepthDataDeliverySupported, output.isDepthDataDeliveryEnabled != rollback.depthDelivery {
                output.isDepthDataDeliveryEnabled = rollback.depthDelivery
            }
            if output.isPortraitEffectsMatteDeliverySupported, output.isPortraitEffectsMatteDeliveryEnabled != rollback.matteDelivery {
                output.isPortraitEffectsMatteDeliveryEnabled = rollback.matteDelivery
            }
        }
        refreshOutputMaxPhotoDimensions()
        applyFeatureIntents()
    }

    /// `factor` clamped to the Cinematic Video zoom range while Cinematic Video is enabled;
    /// unchanged otherwise.
    func cinematicClampedZoom(_ factor: CGFloat) -> CGFloat {
        guard #available(iOS 26.0, *), isCinematicVideoCaptureActive, let format = videoDevice?.activeFormat else {
            return factor
        }
        return Self.clampedZoom(
            factor,
            min: format.videoMinZoomFactorForCinematicVideo,
            max: format.videoMaxZoomFactorForCinematicVideo
        )
    }

    /// Clamps a raw zoom factor into the cinematic range (ignored when the range is empty).
    nonisolated static func clampedZoom(_ zoom: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard lower > 0, upper >= lower else { return zoom }
        return Swift.min(Swift.max(zoom, lower), upper)
    }

    func applyCinematicMetadataCapturePolicy() {
        guard #available(iOS 27.0, *), let output = movieFileOutput else { return }
        switch cinematicMetadataCapture {
        case .automatic:
            if !output.automaticallyAdjustsCinematicVideoMetadataCaptureEnabled {
                output.automaticallyAdjustsCinematicVideoMetadataCaptureEnabled = true
            }
        case .enabled, .disabled:
            if output.automaticallyAdjustsCinematicVideoMetadataCaptureEnabled {
                output.automaticallyAdjustsCinematicVideoMetadataCaptureEnabled = false
            }
            let enable = cinematicMetadataCapture == .enabled && output.isCinematicVideoMetadataCaptureSupported
            if output.isCinematicVideoMetadataCaptureEnabled != enable {
                output.isCinematicVideoMetadataCaptureEnabled = enable
            }
        }
    }
}
