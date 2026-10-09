@preconcurrency import AVFoundation

// MARK: - Detected objects, subject tracking, Cinematic Video

//
// iOS 27 continuous autofocus tracking and iOS 26 Cinematic Video both run through the
// session's metadata output (see `PRMCameraSession+Metadata.swift`). While Cinematic Video
// is enabled AVFoundation owns focus and raises on any focus-mode change, so the focus
// setters in `PRMCamera.swift` route through the guards at the bottom of this file.

public extension PRMCamera {
    // MARK: Detected objects

    /// Objects delivered by the metadata output: the iOS 27 focus-tracked subject, the
    /// faces / bodies / pets Cinematic Video detects, and any types requested through
    /// ``setMetadataObjectTypes(_:)``. Coalesced to the latest batch. Nothing arrives until
    /// one of those features is on.
    func detectedObjectsStream() -> AsyncStream<[PRMDetectedObject]> {
        session.metadataRouter.detectedObjects()
    }

    /// Requests extra metadata types (faces, bodies, pets, …) on
    /// ``detectedObjectsStream()``. Attaches the metadata output if needed.
    func setMetadataObjectTypes(_ types: [AVMetadataObject.ObjectType]) async {
        await session.setMetadataObjectTypes(types)
        _ = await session.awaitPhotoOutputReady()
    }

    // MARK: Continuous autofocus tracking (iOS 27)

    /// Turns subject tracking on or off (iOS 27). Once on, a tap with
    /// `focusMode: .continuousAutoFocus` in
    /// ``setFocusAndExposure(focusMode:exposureMode:at:monitorSubjectAreaChange:)`` tracks
    /// the tapped subject; ``PRMCameraState/isContinuousAutoFocusTrackingSubjectAcquired``
    /// reports progress and ``detectedObjectsStream()`` carries its bounds. Refused while
    /// Cinematic Video is enabled.
    func setContinuousAutoFocusTrackingEnabled(_ enabled: Bool) async {
        do {
            try await session.setContinuousAutoFocusTrackingEnabled(enabled)
        } catch {
            emitAnyError(error)
        }
        _ = await session.awaitPhotoOutputReady()
        await refreshState()
    }

    /// Biases tracked focus toward the subject's nearest (-1) or farthest (1) part
    /// (iOS 27). Requires tracking to be enabled.
    func setContinuousAutoFocusTrackingBias(_ bias: Float) async {
        do {
            try await session.setContinuousAutoFocusTrackingBias(bias)
        } catch {
            emitAnyError(error)
        }
        await refreshState()
    }

    // MARK: Cinematic Video (iOS 26)

    /// Turns Cinematic Video capture on or off (iOS 26). Enabling switches to a Cinematic
    /// format, attaches the movie output (Live Photo off) and the metadata output, and
    /// turns subject tracking off; record with ``PRMVideoRecorder`` as usual.
    ///
    /// When the current camera has no Cinematic Video format (the Triple camera Pro iPhones
    /// open by default), enabling first switches to the camera at the same position that does
    /// (``PRMCameraDevice/cinematicVideoDeviceType``), and disabling switches back unless the
    /// app changed cameras in between. ``device`` changes either way. It stays on across
    /// ``switchCamera(to:)``, which lands on the new position's Cinematic camera, and across
    /// ``switchDevice(type:position:)`` when the new camera supports it.
    ///
    /// While it's on, focus belongs to Cinematic Video: tap-to-focus becomes
    /// ``setCinematicFocus(_:)`` with `.trackPoint`, and manual focus, frame-rate changes,
    /// 48MP and depth formats are refused (with an error on ``errorStream()``).
    ///
    /// - Parameters:
    ///   - enabled: Turn Cinematic Video on or off.
    ///   - targetPhotoOutputAttached: See
    ///     ``PRMCameraSession/setCinematicVideoCaptureEnabled(_:targetPhotoOutputAttached:)``.
    /// - Throws: As ``PRMCameraSession/setCinematicVideoCaptureEnabled(_:targetPhotoOutputAttached:)``.
    func setCinematicVideoEnabled(_ enabled: Bool, targetPhotoOutputAttached: Bool? = nil) async throws {
        if enabled {
            try await moveToCinematicVideoCamera()
        }
        do {
            try await session.setCinematicVideoCaptureEnabled(enabled, targetPhotoOutputAttached: targetPhotoOutputAttached)
        } catch {
            // A failed enable may still have committed (the format attempt and its
            // rollback), so let the rebuild settle like any other mutation.
            _ = await session.awaitPhotoOutputReady()
            // An overtaken enable leaves the camera to the toggle or switch that overtook it.
            if enabled, !(error is CancellationError), (error as? PRMSessionError) != .cancelled {
                await returnFromCinematicVideoCamera()
            }
            await refreshDevice()
            await refreshState()
            throw error
        }
        _ = await session.awaitPhotoOutputReady()
        if !enabled {
            await returnFromCinematicVideoCamera()
        }
        await refreshDevice()
        await refreshState()
    }

    /// Sends a Cinematic Video focus command (iOS 26): track a detected object (by its
    /// ``PRMDetectedObject/objectID``), track whatever is at a point, or fix focus at a
    /// point's distance. Refused unless Cinematic Video is enabled.
    func setCinematicFocus(_ request: PRMCinematicFocusRequest) async {
        let thrown = await runOnDeviceCheckingCinematic { device, cinematic in
            guard #available(iOS 26.0, *), cinematic else {
                throw PRMSessionError.unsupportedConfiguration("Enable Cinematic Video before setting Cinematic focus")
            }
            try device.prm_setCinematicFocus(request)
        }
        if let thrown {
            emitAnyError(thrown)
        } else if await session.videoDevice == nil {
            emitError(.unsupportedConfiguration("Enable Cinematic Video before setting Cinematic focus"))
        }
    }

    /// Sets the Cinematic Video depth-of-field 𝑓-number (iOS 26) and returns the value
    /// applied after clamping, or `nil` (with an error on ``errorStream()``) when it can't
    /// be set: Cinematic Video off, recording, or a fixed simulated aperture.
    @discardableResult
    func setCinematicSimulatedAperture(_ fNumber: Float) async -> Float? {
        do {
            let applied = try await session.setCinematicSimulatedAperture(fNumber)
            clearThrottledLogs(for: "setCinematicSimulatedAperture")
            await refreshState()
            return applied
        } catch {
            // Slider-driven: logged once per error until a call succeeds.
            emitAnyError(error, throttledBy: "setCinematicSimulatedAperture")
            return nil
        }
    }

    /// Chooses whether recordings carry Cinematic Video metadata for post-capture focus
    /// editing (iOS 27).
    func setCinematicMetadataCapture(_ policy: PRMCinematicMetadataCapture) async {
        await session.setCinematicMetadataCapture(policy)
        _ = await session.awaitPhotoOutputReady()
        await refreshState()
    }
}

// MARK: - Cinematic Video camera

/// A camera switch Cinematic Video made: from `deviceType` to `cinematicDeviceType` at
/// `position`.
struct CinematicReturn: Equatable {
    let deviceType: AVCaptureDevice.DeviceType
    let cinematicDeviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
}

extension PRMCamera {
    /// Switches to the camera Cinematic Video runs on when the current one has no Cinematic
    /// Video format, remembering the current one for ``returnFromCinematicVideoCamera()``.
    /// Leaves the camera alone when no camera at this position supports it, so the enable
    /// reports that.
    private func moveToCinematicVideoCamera() async throws {
        guard let current = device, !current.supportsCinematicVideo,
              let type = current.cinematicVideoDeviceType, type != current.deviceType
        else { return }
        PRMLog.notice(
            .session,
            "Cinematic Video: \(current.deviceType.prm_logName) has no Cinematic Video format, switching to \(type.prm_logName)"
        )
        try await switchDevice(type: type, position: current.position)
        cinematicReturn = CinematicReturn(deviceType: current.deviceType, cinematicDeviceType: type, position: current.position)
    }

    /// Goes back to the camera ``moveToCinematicVideoCamera()`` left, unless the app has
    /// changed cameras since.
    private func returnFromCinematicVideoCamera() async {
        guard let target = cinematicReturn else { return }
        cinematicReturn = nil
        guard let current = device, current.deviceType == target.cinematicDeviceType, current.position == target.position else { return }
        PRMLog.notice(.session, "Cinematic Video off: switching back to \(target.deviceType.prm_logName)")
        do {
            try await switchDevice(type: target.deviceType, position: target.position)
        } catch {
            emitAnyError(error)
        }
    }

    /// The switch ``switchCamera(to:)`` makes instead of landing on the position's usual
    /// camera while Cinematic Video is on, or `nil` when the usual camera will do.
    func cinematicVideoCamera(at position: AVCaptureDevice.Position) async -> CinematicReturn? {
        guard #available(iOS 26.0, *), await session.wantsCinematicVideo,
              let usual = await session.defaultVideoDeviceType(at: position)
        else { return nil }
        if let usualDevice = AVCaptureDevice.default(usual, for: .video, position: position),
           usualDevice.formats.contains(where: \.isCinematicVideoCaptureSupported) {
            return nil
        }
        guard let type = PRMCameraDevice.cinematicVideoDeviceType(at: position), type != usual else { return nil }
        return CinematicReturn(deviceType: usual, cinematicDeviceType: type, position: position)
    }
}

// MARK: - Cinematic Video guards

extension PRMCamera {
    /// Re-enables Cinematic Video after a camera switch (the new input starts without it).
    /// Called once the swap's rebuild has settled, so the two rebuilds run one at a time.
    func reapplyCinematicVideoAfterSwitch() async {
        guard await session.wantsCinematicVideo else { return }
        do {
            try await session.reapplyCinematicVideoCaptureIfNeeded()
        } catch PRMSessionError.cancelled {
            // A later toggle or switch took over; it reports its own outcome.
        } catch {
            emitAnyError(error)
        }
        // Success or failure, the attempt committed configuration changes.
        _ = await session.awaitPhotoOutputReady()
    }

    /// Tap-to-focus while Cinematic Video is enabled: exposure at the point, and a strong
    /// tracking-focus request for the subject there (focus modes are locked). Runs inside
    /// the camera actor's turn that checked the Cinematic flag.
    nonisolated static func applyCinematicTapFocus(
        on device: AVCaptureDevice,
        exposureMode: AVCaptureDevice.ExposureMode?,
        at devicePoint: CGPoint
    ) throws {
        if let exposureMode {
            try device.prm_setExposurePointOfInterest(devicePoint, mode: exposureMode)
        }
        if #available(iOS 26.0, *) {
            try device.prm_setCinematicFocus(.trackPoint(devicePoint, mode: .strong))
        }
    }
}
