@preconcurrency import AVFoundation

// MARK: - iOS 26 / 27 feature intents

//
// Device- and format-dependent features (smudge detection, noise reduction, subject
// tracking, dynamic aspect ratio, Smart Framing, the metadata output) are stored as intents
// on the session and re-applied by `applyFeatureIntents()` inside every begin/commit that
// replaces the input, the outputs or the active format. Cinematic Video is handled
// separately (`PRMCameraSession+Cinematic.swift`) because it switches formats itself.

extension PRMCameraSession {
    // MARK: Intents

    /// Resets every intent from a fresh configuration. Called at the top of `configure(_:)`.
    func resetFeatureIntents(from configuration: PRMCameraConfiguration) {
        requestedMetadataObjectTypes = configuration.metadataObjectTypes
        wantsContinuousAutoFocusTracking = false
        wantsCinematicVideo = configuration.enableCinematicVideo
        cinematicSimulatedApertureIntent = nil
        cinematicMetadataCapture = .automatic
        lensSmudgeDetectionInterval = configuration.lensSmudgeDetectionInterval
        lowLightVideoNoiseReduction = .automatic
        desiredDynamicAspectRatio = nil
        smartFramingIntent = nil
        wantsHighResolutionPhotoFormat = configuration.prefersMaxPhotoDimensionsFormat
        stabilizationMode = configuration.preferredVideoStabilizationMode
        cinematicGeneration += 1
    }

    /// Re-applies every device/format-dependent intent to the current input, outputs and
    /// active format. Idempotent; call it inside an open begin/commit.
    func applyFeatureIntents() {
        applyStabilization()
        reconcileMetadataOutput()
        applyContinuousAutoFocusTracking()
        applyLensSmudgeDetection()
        applyLowLightVideoNoiseReduction()
        applyDynamicAspectRatio()
        applySmartFramingFramings()
        applyCinematicMetadataCapturePolicy()
        if isRunning {
            startSmartFramingMonitoringIfNeeded()
        }
    }

    // MARK: Deferred start (iOS 26)

    /// Applies ``PRMCameraConfiguration/deferredStart`` to a freshly added output.
    func applyDeferredStart(to output: AVCaptureOutput, isPreview: Bool) {
        guard #available(iOS 26.0, *), let mode = configuration?.deferredStart else { return }
        switch mode {
        case .systemDefault:
            return
        case .disabled:
            if output.isDeferredStartEnabled {
                output.isDeferredStartEnabled = false
            }
        case .photoAndMovie:
            let wantsDeferral = !isPreview && (output is AVCapturePhotoOutput || output is AVCaptureFileOutput)
            if wantsDeferral, !output.isDeferredStartSupported { return }
            if output.isDeferredStartEnabled != wantsDeferral {
                output.isDeferredStartEnabled = wantsDeferral
            }
        }
    }

    // MARK: Lens smudge detection (iOS 26)

    /// Turns smudge detection on (with `interval`) or off. `nil` = off, `.invalid` = once
    /// per session start, `.zero` = continuously. Rebuilds the capture pipeline; no-op
    /// where unsupported. Results arrive in ``PRMCameraState/lensSmudgeStatus``.
    public func setLensSmudgeDetection(interval: CMTime?) {
        lensSmudgeDetectionInterval = interval
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyLensSmudgeDetection()
    }

    func applyLensSmudgeDetection() {
        guard #available(iOS 26.0, *), let device = videoDevice,
              device.activeFormat.isCameraLensSmudgeDetectionSupported
        else { return }
        let wanted = lensSmudgeDetectionInterval
        let enabled = device.isCameraLensSmudgeDetectionEnabled
        if let wanted {
            guard !enabled || !Self.sameDetectionInterval(device.cameraLensSmudgeDetectionInterval, wanted) else { return }
        } else {
            guard enabled else { return }
        }
        do {
            try device.prm_withConfigurationLock {
                device.setCameraLensSmudgeDetectionEnabled(wanted != nil, detectionInterval: wanted ?? .invalid)
            }
        } catch {
            PRMLog.warning(.session, "Lens smudge detection change failed", error: error)
        }
    }

    /// `CMTime` equality that also treats two invalid times ("run once") as equal.
    nonisolated static func sameDetectionInterval(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        if !lhs.isValid || !rhs.isValid { return lhs.isValid == rhs.isValid }
        return CMTimeCompare(lhs, rhs) == 0
    }

    // MARK: Low-light video noise reduction (iOS 27)

    /// Sets the low-light video noise reduction policy on the movie and video-data
    /// connections. `.automatic` leaves it to the system (on for recording where supported).
    public func setLowLightVideoNoiseReduction(_ mode: PRMLowLightVideoNoiseReduction) {
        lowLightVideoNoiseReduction = mode
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyLowLightVideoNoiseReduction()
    }

    /// Whether noise reduction is active on the movie or video-data connection.
    public var isLowLightVideoNoiseReductionActive: Bool {
        guard #available(iOS 27.0, *) else { return false }
        let movie = movieFileOutput?.connection(with: .video)?.isLowLightVideoNoiseReductionEnabled ?? false
        let data = videoDataOutput?.connection(with: .video)?.isLowLightVideoNoiseReductionEnabled ?? false
        return movie || data
    }

    func applyLowLightVideoNoiseReduction() {
        guard #available(iOS 27.0, *) else { return }
        let movieConnection = movieFileOutput?.connection(with: .video)
        let dataConnection = videoDataOutput?.connection(with: .video)
        switch lowLightVideoNoiseReduction {
        case .automatic:
            // The SDK default: automatic on movie connections. The preview connection goes
            // back to off if an earlier `.on` forced it.
            if let movieConnection, !movieConnection.automaticallyEnablesLowLightVideoNoiseReduction {
                movieConnection.automaticallyEnablesLowLightVideoNoiseReduction = true
            }
            if let dataConnection, !dataConnection.automaticallyEnablesLowLightVideoNoiseReduction,
               dataConnection.isLowLightVideoNoiseReductionEnabled {
                dataConnection.isLowLightVideoNoiseReductionEnabled = false
            }
        case .on, .off:
            // Inside an open configuration right after a format swap the connection's support
            // flag may lag the format's; require both before enabling (enabling an
            // unsupported connection raises).
            let formatSupports = videoDevice?.activeFormat.isLowLightVideoNoiseReductionSupported ?? false
            for connection in [movieConnection, dataConnection].compactMap(\.self) {
                if connection.automaticallyEnablesLowLightVideoNoiseReduction {
                    connection.automaticallyEnablesLowLightVideoNoiseReduction = false
                }
                let enable = lowLightVideoNoiseReduction == .on && formatSupports
                    && connection.isLowLightVideoNoiseReductionSupported
                if connection.isLowLightVideoNoiseReductionEnabled != enable {
                    connection.isLowLightVideoNoiseReductionEnabled = enable
                }
            }
        }
    }

    // MARK: Dynamic aspect ratio (iOS 26)

    /// Changes the device's output aspect ratio (iOS 26; e.g. the iPhone 17 square-sensor
    /// front camera framing landscape while the phone is upright). Returns once the first
    /// buffer at the new ratio is produced. The ratio is kept and re-applied after camera
    /// switches and format changes wherever it's supported.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` before iOS 26, while
    ///   recording, when the session isn't running (no frame would ever confirm the
    ///   change), when the active format doesn't offer `ratio`, or when no frame confirms
    ///   the change within two seconds.
    public func setDynamicAspectRatio(_ ratio: PRMAspectRatio) async throws {
        guard #available(iOS 26.0, *), let device = videoDevice else {
            throw PRMSessionError.unsupportedConfiguration("Dynamic aspect ratio requires iOS 26")
        }
        try refuseWhileBusy("Changing the aspect ratio")
        guard session.isRunning, !session.isInterrupted else {
            throw PRMSessionError.unsupportedConfiguration("Start the session before changing the aspect ratio")
        }
        _ = try await device.prm_setDynamicAspectRatio(ratio)
        // Kept only once it took, so a refused ratio isn't applied later to a camera that
        // supports it.
        desiredDynamicAspectRatio = ratio
    }

    func applyDynamicAspectRatio() {
        guard #available(iOS 26.0, *), let ratio = desiredDynamicAspectRatio, let device = videoDevice else { return }
        let avRatio = ratio.avAspectRatio
        guard device.dynamicAspectRatio != avRatio,
              device.activeFormat.supportedDynamicAspectRatios.contains(avRatio)
        else { return }
        PRMLog.bestEffort(.session, "applyDynamicAspectRatio(\(ratio.rawValue))") {
            try device.prm_withConfigurationLock {
                device.setDynamicAspectRatio(avRatio, completionHandler: nil)
            }
        }
    }

    // MARK: Smart Framing (iOS 26)

    /// Framings the current device's Smart Framing monitor can recommend. Empty when the
    /// device has no monitor (anything but supported ultra-wide front cameras) or before
    /// iOS 26.
    public func supportedFramings() -> [PRMFraming] {
        guard #available(iOS 26.0, *), let monitor = videoDevice?.smartFramingMonitor else { return [] }
        return monitor.supportedFramings.compactMap(PRMFraming.init)
    }

    /// Chooses which framings Smart Framing may recommend and starts monitoring (`nil`
    /// stops it). Pick from ``supportedFramings()``. Recommendations arrive on
    /// ``PRMCamera/framingRecommendationStream()``; nothing is applied automatically.
    public func setSmartFraming(enabledFramings: [PRMFraming]?) {
        smartFramingIntent = enabledFramings
        guard enabledFramings != nil else {
            stopSmartFramingMonitoring()
            applySmartFramingFramings()
            return
        }
        applySmartFramingFramings()
        if isRunning {
            startSmartFramingMonitoringIfNeeded()
        }
    }

    func applySmartFramingFramings() {
        guard #available(iOS 26.0, *), let monitor = videoDevice?.smartFramingMonitor else { return }
        let wanted = Set(smartFramingIntent ?? [])
        let matched = monitor.supportedFramings.filter { framing in
            PRMFraming(framing).map(wanted.contains) ?? false
        }
        if monitor.enabledFramings != matched {
            monitor.enabledFramings = matched
        }
    }

    func startSmartFramingMonitoringIfNeeded() {
        guard #available(iOS 26.0, *), smartFramingIntent != nil, let device = videoDevice,
              device.activeFormat.isSmartFramingSupported,
              let monitor = device.smartFramingMonitor, !monitor.isMonitoring
        else { return }
        do {
            try monitor.startMonitoring()
        } catch {
            PRMLog.warning(.session, "Smart Framing monitoring failed to start", error: error)
        }
    }

    func stopSmartFramingMonitoring() {
        guard #available(iOS 26.0, *), let monitor = videoDevice?.smartFramingMonitor, monitor.isMonitoring else { return }
        monitor.stopMonitoring()
    }
}
