@preconcurrency import AVFoundation

/// What a Night capture set up and what it changed, so it can put the camera back. Built and
/// consumed on the camera actor.
struct PRMNightCaptureLease: @unchecked Sendable {
    let plan: PRMNightPlan
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format
    let exposureMode: AVCaptureDevice.ExposureMode
    let exposureDuration: CMTime
    let iso: Float
    let exposureBias: Float
    let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
    let focusMode: AVCaptureDevice.FocusMode
    let subjectAreaMonitoring: Bool
    let minFrameDuration: CMTime
    let maxFrameDuration: CMTime
    let autoVideoFrameRate: Bool
    /// The video-data connection's angle and mirroring (how the frames arrive).
    let dataRotation: CGFloat
    let dataMirrored: Bool
    /// The photo connection's (how a photo would be saved); the data connection's without one.
    let photoRotation: CGFloat
    let photoMirrored: Bool
    /// The session moved to `.inputPriority` because the `.photo` preset delivered frames
    /// smaller than the format.
    var switchedToInputPriority = false
}

extension PRMCameraSession {
    // MARK: - Planning

    /// The plan a Night capture would use right now, or `nil` without a camera.
    func nightPlan(options: PRMNightModeOptions) -> PRMNightPlan? {
        guard let device = videoDevice else { return nil }
        return PRMNightPlanner.plan(Self.nightPlanInput(device: device, isStable: options.isStable), duration: options.duration)
    }

    nonisolated static func nightPlanInput(device: AVCaptureDevice, isStable: Bool) -> PRMNightPlanInput {
        let format = device.activeFormat
        var focalLength = device.prm_nominalFocalLength35mm
        if focalLength <= 0 {
            // A 35mm frame is 36 mm wide; the field of view is across the sensor's long side.
            let halfAngle = Double(format.videoFieldOfView) * .pi / 360
            focalLength = halfAngle > 0 ? 18 / tan(halfAngle) : 26
        }
        let duration = CMTimeGetSeconds(device.exposureDuration)
        return PRMNightPlanInput(
            exposureDuration: duration.isFinite && duration > 0 ? duration : 1.0 / 30.0,
            iso: device.iso,
            targetOffset: device.exposureTargetOffset,
            minISO: format.minISO,
            maxISO: format.maxISO,
            minExposureDuration: CMTimeGetSeconds(format.minExposureDuration),
            maxExposureDuration: CMTimeGetSeconds(format.maxExposureDuration),
            focalLength35mm: focalLength,
            isStable: isStable
        )
    }

    // MARK: - Lease

    /// Checks that a Night capture can run, plans it, snapshots what it will change, and
    /// takes the camera: until ``endNightCapture(_:)`` reconfigurations and device controls
    /// are refused (``refuseWhileBusy(_:)``).
    ///
    /// `frameDimensions` is what the video-data output delivers; when it's smaller than the
    /// format (the `.photo` preset can scale the stream), the session moves to
    /// `.inputPriority` for the capture so frames come at full size.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while recording, with
    ///   Cinematic Video or Live Photo on, or without a camera or video-data output;
    ///   ``PRMSessionError/virtualDeviceManualControlUnsupported(_:)`` on a virtual
    ///   multi-camera device; ``PRMSessionError/exposureCombinationUnsupported`` on a camera
    ///   without custom exposure.
    func beginNightCapture(options: PRMNightModeOptions, frameDimensions: CMVideoDimensions?) async throws -> PRMNightCaptureLease {
        try refuseWhileBusy("Night capture")
        guard let device = videoDevice, let dataConnection = videoDataOutput?.connection(with: .video) else {
            throw PRMSessionError.unsupportedConfiguration("Night capture needs a camera and a video data output")
        }
        if isCinematicVideoCaptureActive {
            throw PRMSessionError.unsupportedConfiguration("Night capture isn't available while Cinematic Video is enabled")
        }
        if photoOutput?.isLivePhotoCaptureEnabled == true {
            throw PRMSessionError.unsupportedConfiguration("Turn Live Photo off for Night capture: it overrides manual exposure")
        }
        if device.prm_isVirtualMultiCameraDevice {
            throw PRMSessionError.virtualDeviceManualControlUnsupported(device.deviceType)
        }
        guard device.isExposureModeSupported(.custom) else {
            throw PRMSessionError.exposureCombinationUnsupported
        }

        // Plan and snapshot from the settled preview. A preset change restarts auto
        // exposure, and read right after one it reports a transient shutter (NaN, or far
        // shorter than the preview had settled on) that would plan frames too dark.
        let photoConnection = photoOutput?.connection(with: .video)
        let targetOffset = device.exposureTargetOffset
        let plan = PRMNightPlanner.plan(Self.nightPlanInput(device: device, isStable: options.isStable), duration: options.duration)
        var lease = PRMNightCaptureLease(
            plan: plan,
            device: device,
            format: device.activeFormat,
            exposureMode: device.exposureMode,
            exposureDuration: device.exposureDuration,
            iso: device.iso,
            exposureBias: device.exposureTargetBias,
            whiteBalanceMode: device.whiteBalanceMode,
            focusMode: device.focusMode,
            subjectAreaMonitoring: device.isSubjectAreaChangeMonitoringEnabled,
            minFrameDuration: device.activeVideoMinFrameDuration,
            maxFrameDuration: device.activeVideoMaxFrameDuration,
            autoVideoFrameRate: device.isAutoVideoFrameRateEnabled,
            dataRotation: dataConnection.videoRotationAngle,
            dataMirrored: dataConnection.isVideoMirrored,
            photoRotation: photoConnection?.videoRotationAngle ?? dataConnection.videoRotationAngle,
            photoMirrored: photoConnection?.isVideoMirrored ?? dataConnection.isVideoMirrored
        )
        // Taken before the preset change below waits for the rebuild, so nothing else can
        // reconfigure the camera meanwhile.
        exclusiveCaptureOwner = "a Night capture"
        let autoDuration = CMTimeGetSeconds(lease.exposureDuration)
        PRMLog.notice(
            .capture,
            """
            Night: \(plan.frameCount) frames at \(String(format: "%.3f", plan.frameDuration)) s ISO \(Int(plan.iso)) \
            over \(String(format: "%.1f", plan.duration)) s (auto was \(autoDuration.isFinite ? String(format: "%.3f", autoDuration) : "n/a") s \
            ISO \(Int(lease.iso)), offset \(String(format: "%.2f", targetOffset)) EV)
            """
        )

        let formatDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if let frameDimensions,
           Int(frameDimensions.width) * Int(frameDimensions.height) < Int(formatDimensions.width) * Int(formatDimensions.height) * 9 / 10,
           session.sessionPreset != .inputPriority, session.canSetSessionPreset(.inputPriority) {
            PRMLog.notice(
                .capture,
                """
                Night: frames are \(frameDimensions.width)×\(frameDimensions.height) under \(session.sessionPreset.prm_logName), \
                the format is \(formatDimensions.width)×\(formatDimensions.height); switching to InputPriority for the capture
                """
            )
            let format = device.activeFormat
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            if device.activeFormat !== format {
                try? device.prm_withConfigurationLock { device.activeFormat = format }
            }
            refreshVideoDataOutputPixelFormat()
            session.commitConfiguration()
            lease.switchedToInputPriority = true
            _ = await awaitPhotoOutputReady()
        }
        return lease
    }

    /// Sets the plan's exposure and locks white balance and focus for the burst; takes
    /// stabilization and low-light noise reduction off the frames (both blend frames over
    /// time). Returns once a frame confirmed the exposure.
    func applyNightExposure(_ lease: PRMNightCaptureLease) async throws {
        let device = lease.device
        try device.prm_withConfigurationLock {
            if device.isAutoVideoFrameRateEnabled {
                device.isAutoVideoFrameRateEnabled = false
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
        }
        if let connection = videoDataOutput?.connection(with: .video) {
            var changes = false
            if connection.isVideoStabilizationSupported, connection.preferredVideoStabilizationMode != .off {
                changes = true
            }
            if #available(iOS 27.0, *), connection.automaticallyEnablesLowLightVideoNoiseReduction || connection.isLowLightVideoNoiseReductionEnabled {
                changes = true
            }
            if changes {
                session.beginConfiguration()
                connection.prm_setStabilization(.off)
                if #available(iOS 27.0, *) {
                    connection.automaticallyEnablesLowLightVideoNoiseReduction = false
                    if connection.isLowLightVideoNoiseReductionEnabled {
                        connection.isLowLightVideoNoiseReductionEnabled = false
                    }
                }
                session.commitConfiguration()
            }
        }
        let duration = CMTimeMakeWithSeconds(lease.plan.frameDuration, preferredTimescale: 1_000_000)
        _ = try await device.prm_setCustomExposure(duration: duration, iso: lease.plan.iso, timeout: 3)
    }

    /// Puts back everything ``beginNightCapture(options:frameDimensions:)`` and
    /// ``applyNightExposure(_:)`` changed and releases the camera. Safe after a partial
    /// setup.
    func endNightCapture(_ lease: PRMNightCaptureLease) async {
        let device = lease.device
        if device === videoDevice {
            do {
                try device.prm_withConfigurationLock {
                    if lease.exposureMode == .custom {
                        device.setExposureModeCustom(
                            duration: device.prm_clampedDuration(lease.exposureDuration),
                            iso: min(max(lease.iso, device.activeFormat.minISO), device.activeFormat.maxISO),
                            completionHandler: nil
                        )
                    } else if device.isExposureModeSupported(lease.exposureMode) {
                        device.prm_restoreExposureAutoTracking()
                        device.exposureMode = lease.exposureMode
                    }
                    if lease.exposureBias != device.exposureTargetBias {
                        device.setExposureTargetBias(lease.exposureBias, completionHandler: nil)
                    }
                    if device.isWhiteBalanceModeSupported(lease.whiteBalanceMode) {
                        device.whiteBalanceMode = lease.whiteBalanceMode
                    }
                    if device.isFocusModeSupported(lease.focusMode) {
                        device.focusMode = lease.focusMode
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = lease.subjectAreaMonitoring
                    // The custom exposure lengthened the frame duration. Restore it after the
                    // exposure mode (shortening it first would cut a custom exposure short),
                    // and only on the same format (the old durations may not fit another).
                    if !lease.autoVideoFrameRate, !lease.switchedToInputPriority, device.activeFormat === lease.format {
                        device.activeVideoMinFrameDuration = lease.minFrameDuration
                        device.activeVideoMaxFrameDuration = lease.maxFrameDuration
                    }
                    if lease.autoVideoFrameRate, !device.isAutoVideoFrameRateEnabled {
                        device.isAutoVideoFrameRateEnabled = true
                    }
                }
            } catch {
                PRMLog.warning(.capture, "Night: restoring the camera failed", error: error)
            }
        }
        session.beginConfiguration()
        applyStabilization()
        applyLowLightVideoNoiseReduction()
        session.commitConfiguration()
        exclusiveCaptureOwner = nil
        if lease.switchedToInputPriority {
            // Back to the configured preset, with the default frame durations.
            do {
                try resetFrameRate()
            } catch {
                PRMLog.warning(.capture, "Night: restoring the session preset failed", error: error)
            }
            _ = await awaitPhotoOutputReady()
        }
    }
}
