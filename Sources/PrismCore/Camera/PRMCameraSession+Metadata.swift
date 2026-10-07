@preconcurrency import AVFoundation

// MARK: - Metadata output and subject tracking

//
// One `AVCaptureMetadataOutput` serves three clients: iOS 27 continuous autofocus tracking
// (which only reports progress when `.focusTrackedObject` is subscribed), iOS 26 Cinematic
// Video (which requires its own fixed type list), and consumer-requested types. It's
// attached the first time any of them needs it and then kept: detaching would cost another
// pipeline rebuild for no benefit.

extension PRMCameraSession {
    // MARK: Consumer types

    /// Replaces the consumer-requested metadata types delivered on
    /// ``PRMMetadataRouter/detectedObjects()``. Types the device can't produce are dropped.
    /// While Cinematic Video is enabled its own type list wins.
    public func setMetadataObjectTypes(_ types: [AVMetadataObject.ObjectType]) {
        requestedMetadataObjectTypes = types
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        reconcileMetadataOutput()
    }

    // MARK: Reconcile

    /// Attaches the metadata output if any feature needs it and sets its object types.
    /// Call inside an open begin/commit; the available types change with the input and
    /// active format, and the type setter raises on anything not currently available.
    func reconcileMetadataOutput() {
        let cinematicActive = isCinematicVideoCaptureActive
        let needsOutput = configuration?.includesMetadataOutput == true
            || !requestedMetadataObjectTypes.isEmpty
            || wantsContinuousAutoFocusTracking
            || cinematicActive
        guard needsOutput else {
            // Kept attached (detaching costs another rebuild), but stop every detector.
            if let metadataOutput, !metadataOutput.metadataObjectTypes.isEmpty {
                metadataOutput.metadataObjectTypes = []
                metadataRouter.reset()
            }
            return
        }

        if metadataOutput == nil {
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                PRMLog.warning(.session, "Cannot add metadata output; tracking and detection metadata unavailable")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(metadataRouter, queue: metadataOutputQueue)
            // Metadata isn't needed for the first preview frame. A non-deferred streaming
            // output also holds deferred start back until it delivers something, which a
            // metadata output may never do in an empty scene.
            if #available(iOS 26.0, *), configuration?.deferredStart != .disabled, output.isDeferredStartSupported {
                output.isDeferredStartEnabled = true
            }
            metadataOutput = output
        }
        guard let output = metadataOutput else { return }

        var cinematicRequired: [AVMetadataObject.ObjectType] = []
        if #available(iOS 26.0, *) {
            cinematicRequired = output.requiredMetadataObjectTypesForCinematicVideoCapture
        }
        var trackingType: AVMetadataObject.ObjectType?
        if #available(iOS 27.0, *), wantsContinuousAutoFocusTracking {
            trackingType = .focusTrackedObject
        }
        let types = Self.effectiveMetadataObjectTypes(
            available: output.availableMetadataObjectTypes,
            cinematicRequired: cinematicRequired,
            cinematicEnabled: cinematicActive,
            focusTrackedType: trackingType,
            consumer: requestedMetadataObjectTypes
        )
        if output.metadataObjectTypes != types {
            output.metadataObjectTypes = types
            metadataRouter.reset()
        }
    }

    /// The type list to set on the metadata output. Pure, so it's unit-testable.
    ///
    /// - With Cinematic Video on: exactly the types Cinematic Video requires, unfiltered.
    ///   The SDK raises unless `metadataObjectTypes` equals that list once the input has
    ///   Cinematic Video enabled.
    /// - Otherwise: the focus-tracked type (when tracking is wanted), then the consumer's
    ///   types, without duplicates, and only types in `available` (the setter raises on
    ///   anything else).
    nonisolated static func effectiveMetadataObjectTypes(
        available: [AVMetadataObject.ObjectType],
        cinematicRequired: [AVMetadataObject.ObjectType],
        cinematicEnabled: Bool,
        focusTrackedType: AVMetadataObject.ObjectType?,
        consumer: [AVMetadataObject.ObjectType]
    ) -> [AVMetadataObject.ObjectType] {
        if cinematicEnabled { return cinematicRequired }
        let availableSet = Set(available)
        let candidates = [focusTrackedType].compactMap(\.self) + consumer
        var seen = Set<AVMetadataObject.ObjectType>()
        return candidates.filter { availableSet.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Continuous autofocus tracking (iOS 27)

    /// Turns continuous autofocus subject tracking on or off (iOS 27). Attaches the
    /// metadata output and subscribes it to `.focusTrackedObject` in the same commit (the
    /// SDK delivers no tracking updates without it). Once on, a continuous-AF tap-to-focus
    /// starts tracking the tapped subject. The setting survives camera switches wherever
    /// the new device supports it.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` before iOS 27, when the
    ///   active format doesn't support tracking, or while Cinematic Video is enabled.
    public func setContinuousAutoFocusTrackingEnabled(_ enabled: Bool) throws {
        if enabled {
            if isCinematicVideoCaptureActive {
                throw PRMSessionError.unsupportedConfiguration("Subject tracking can't run while Cinematic Video is enabled")
            }
            guard videoDevice?.prm_isContinuousAutoFocusTrackingSupported == true else {
                throw PRMSessionError.unsupportedConfiguration("Continuous autofocus tracking requires iOS 27 and a supporting format")
            }
        }
        wantsContinuousAutoFocusTracking = enabled
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        reconcileMetadataOutput()
        applyContinuousAutoFocusTracking()
    }

    /// Biases tracked focus toward the subject's nearest (-1) or farthest (1) part, and
    /// re-targets at the last tracked subject so the re-trigger doesn't jump to a stale
    /// point (iOS 27).
    public func setContinuousAutoFocusTrackingBias(_ bias: Float) throws {
        guard let device = videoDevice else {
            throw PRMSessionError.unsupportedConfiguration("No video device")
        }
        try device.prm_setContinuousAutoFocusTrackingBias(
            bias,
            retargetingAt: metadataRouter.lastFocusTrackedObject?.center
        )
    }

    func applyContinuousAutoFocusTracking() {
        guard let device = videoDevice else { return }
        let shouldTrack = wantsContinuousAutoFocusTracking
            && !isCinematicVideoCaptureActive
            && device.prm_isContinuousAutoFocusTrackingSupported
        guard shouldTrack != device.prm_isContinuousAutoFocusTrackingEnabled else { return }
        do {
            try device.prm_setContinuousAutoFocusTracking(shouldTrack)
        } catch {
            PRMLog.warning(.session, "Continuous AF tracking change to \(shouldTrack) failed", error: error)
        }
    }
}
