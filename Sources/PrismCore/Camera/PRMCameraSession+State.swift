@preconcurrency import AVFoundation

// MARK: - State snapshot

extension PRMCameraSession {
    /// Device-derived ``PRMCameraState``, read in one actor turn so it can't mix two
    /// devices across a camera switch. `nil` without a video device. Interruption fields are
    /// left at their defaults: ``PRMCamera`` tracks them from notifications.
    func stateSnapshot() -> PRMCameraState? {
        guard let device = videoDevice else { return nil }
        var state = PRMCameraState()
        state.isRunning = isRunning
        state.zoomFactor = device.videoZoomFactor
        state.torchMode = device.torchMode
        state.torchLevel = device.torchLevel
        state.focusMode = device.focusMode
        state.lensPosition = device.lensPosition
        state.exposureMode = device.exposureMode
        state.exposureBias = device.exposureTargetBias
        state.iso = device.iso
        state.isVideoHDREnabled = device.activeFormat.isVideoHDRSupported && device.isVideoHDREnabled
        state.isLowLightBoostActive = device.prm_isLowLightBoostActive
        let durationSeconds = CMTimeGetSeconds(device.exposureDuration)
        state.exposureDurationSeconds = (durationSeconds > 0 && durationSeconds.isFinite) ? durationSeconds : nil
        state.whiteBalanceMode = device.whiteBalanceMode
        let tempTint = device.prm_currentTemperatureAndTint()
        state.whiteBalanceTemperature = tempTint.temperature
        state.whiteBalanceTint = tempTint.tint
        // The recording connection when there is one (the requested mode lands there),
        // otherwise the preview connection.
        if let connection = movieFileOutput?.connection(with: .video) ?? videoDataOutput?.connection(with: .video) {
            state.activeStabilizationMode = connection.activeVideoStabilizationMode
        }
        state.frameRate = device.prm_currentFrameRate()
        // `activePrimaryConstituent` is iOS 16+ and only meaningful on a virtual
        // multi-lens device. On single-lens devices it returns `nil` (correct fallback)
        // — the UI then falls back to the switchover-bucket heuristic.
        state.activePrimaryDeviceType = device.activePrimaryConstituent?.deviceType

        // iOS 26 / 27 (each helper returns its "unavailable" value on older systems).
        state.lensAperture = device.lensAperture
        state.autoExposureAxes = device.prm_autoExposureAxes
        state.activeExposureSignals = device.prm_activeExposureSignals
        state.isPrimaryConstituentLocked = device.prm_isPrimaryConstituentLocked
        state.lensSmudgeStatus = device.prm_lensSmudgeStatus
        state.systemPressure = PRMSystemPressure(device.systemPressureState)
        state.isLowLightVideoNoiseReductionActive = isLowLightVideoNoiseReductionActive
        state.isContinuousAutoFocusTrackingEnabled = device.prm_isContinuousAutoFocusTrackingEnabled
        state.isContinuousAutoFocusTrackingSubjectAcquired = device.prm_isContinuousAutoFocusTrackingSubjectAcquired
        state.continuousAutoFocusTrackingBias = device.prm_continuousAutoFocusTrackingBias
        state.isCinematicVideoCaptureEnabled = isCinematicVideoCaptureActive
        state.cinematicSimulatedAperture = cinematicSimulatedAperture
        state.cinematicSceneStatuses = device.prm_cinematicSceneStatuses
        state.isCinematicVideoMetadataCaptureEnabled = isCinematicVideoMetadataCaptureEnabled
        state.dynamicAspectRatio = device.prm_dynamicAspectRatio
        state.dynamicDimensions = device.prm_dynamicDimensions
        return state
    }
}
