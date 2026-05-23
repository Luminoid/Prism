@preconcurrency import AVFoundation

/// Owns the `AVCaptureSession` and serializes all mutations on ``PRMCameraActor``.
///
/// This is the low-level type. Most consumers should use ``PRMCamera`` (MainActor facade)
/// instead. Direct access is useful when you need to:
/// - call AVFoundation APIs not yet wrapped by `PRMCamera`,
/// - install custom outputs (depth, audio, multi-cam),
/// - integrate with code that already lives on `PRMCameraActor`.
///
/// All public methods are actor-isolated, so callers must `await` them. AVFoundation
/// delegate callbacks land on the actor's underlying queue automatically because the actor
/// is initialized with a custom serial executor.
@PRMCameraActor
public final class PRMCameraSession {
    // MARK: - Properties

    /// The underlying capture session.
    ///
    /// `AVCaptureSession` is not `Sendable`, but its internal queue serializes all access —
    /// safe to read across actors. `nonisolated(unsafe)` documents this.
    public nonisolated(unsafe) let session = AVCaptureSession()

    /// Dedicated queue for AVFoundation delegate callbacks (video data output).
    public nonisolated let dataOutputQueue = DispatchQueue(
        label: "com.luminoid.Prism.DataOutput",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    /// Current configuration.
    public private(set) var configuration: PRMCameraConfiguration?

    /// Current video device.
    public private(set) var videoDevice: AVCaptureDevice?

    /// Current video device input.
    public private(set) var videoDeviceInput: AVCaptureDeviceInput?

    /// Audio input, if attached.
    public private(set) var audioDeviceInput: AVCaptureDeviceInput?

    /// Photo output, if configured.
    public private(set) var photoOutput: AVCapturePhotoOutput?

    /// Video data output (for filter pipeline), if configured.
    public private(set) var videoDataOutput: AVCaptureVideoDataOutput?

    /// Movie file output, if configured.
    public private(set) var movieFileOutput: AVCaptureMovieFileOutput?

    /// Whether `session.startRunning()` has been called.
    public private(set) var isRunning: Bool = false

    /// The `device.activeFormat` snapshot captured at `configure(_:)` and refreshed
    /// at every `switchCamera` / `switchDevice` success. Used by
    /// `applyLivePhotoCompatibleFormat()` as the canonical "restore" target on
    /// Max-Dimensions-OFF — the format AVFoundation picked for our session at
    /// configure time is guaranteed BGRA-capable (we render a preview with it
    /// from the start), whereas any format-scoring heuristic risks picking a
    /// sibling 12MP format whose connection chain excludes BGRA from
    /// `videoDataOutput.availableVideoPixelFormatTypes` (the iPhone 15 Pro Max
    /// portrait-coupled `.photo`-preset format trap — `supportedDepthDataFormats`
    /// is empty for it but `availableVideoPixelFormatTypes` still excludes BGRA).
    /// Captured per device so a wide-camera hop replaces the baseline with that
    /// device's known-good default.
    ///
    /// `internal` so the format-management extension in
    /// ``PRMCameraSession+Format.swift`` can read/write it. Setter access is
    /// otherwise unchanged — only the session itself updates the baseline.
    var baselineActiveFormat: AVCaptureDevice.Format?

    /// The `AVCaptureSession.Preset` AVFoundation was configured with at
    /// ``configure(_:)`` time. Snapshotted so that `PRMCamera.setFrameRate` can
    /// temporarily switch to `.inputPriority` for slo-mo / custom-format captures
    /// and `PRMCamera.resetFrameRate` can restore the original preset when the
    /// session returns to a normal-rate workflow (otherwise the residual
    /// `.inputPriority` state on iPhone Triple Camera can leave the photo output
    /// with no active video connection, which crashes `capturePhoto` at the next
    /// shutter tap with `NSInvalidArgumentException: No active and enabled video
    /// connection`).
    var configuredSessionPreset: AVCaptureSession.Preset?

    // MARK: - Init

    public nonisolated init() {}

    /// Helper that can be called from the MainActor to allocate a session that lives on
    /// ``PRMCameraActor``.
    public nonisolated static func makeDefaultMainActor() -> PRMCameraSession {
        PRMCameraSession()
    }

    // MARK: - Configure

    /// Configures inputs and outputs for the given configuration.
    /// Throws ``PRMSessionError`` if any required resource cannot be added.
    ///
    /// Re-entrant: callers can `configure(_:)` on an already-running session to swap
    /// camera position, device types, session preset, etc. The previous inputs and
    /// outputs are torn down inside the same `beginConfiguration` block so the swap
    /// is atomic from AVFoundation's perspective. (The original implementation only
    /// added — calling it twice left two video inputs attached, with the second
    /// `canAddInput` silently failing and the session stuck on the first device.)
    public func configure(_ configuration: PRMCameraConfiguration) throws {
        configuration.validate()
        self.configuration = configuration

        PRMLogger.trace(
            .session,
            """
            configure(pos=\(configuration.cameraPosition.rawValue), preset=\(configuration.sessionPreset.rawValue), \
            audio=\(configuration.includesAudio), video=\(configuration.includesVideoDataOutput), \
            photo=\(configuration.includesPhotoOutput), movie=\(configuration.includesMovieFileOutput), \
            preferMaxPhoto=\(configuration.prefersMaxPhotoDimensionsFormat))
            """
        )

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        tearDownAttachments()

        session.sessionPreset = configuration.sessionPreset
        configuredSessionPreset = configuration.sessionPreset

        try attachVideoDevice(position: configuration.cameraPosition, types: configuration.deviceTypes)
        #if !os(macOS)
            // Promote `activeFormat` to a 48MP-capable format BEFORE the photo output is
            // attached — `refreshOutputMaxPhotoDimensions` reads
            // `activeFormat.supportedMaxPhotoDimensions` at attach time and pins the
            // output ceiling against it.
            applyPreferredPhotoFormatIfNeeded()
        #endif

        if configuration.includesAudio {
            attachAudioDevice()
        }

        if configuration.includesVideoDataOutput {
            try attachVideoDataOutput(
                pixelFormat: configuration.videoPixelFormat,
                discardsLateVideoFrames: configuration.discardsLateVideoFrames
            )
        }

        if configuration.includesPhotoOutput {
            try attachPhotoOutput(configuration: configuration)
        }

        if configuration.includesMovieFileOutput {
            try attachMovieFileOutput()
        }

        applyPreferredStabilization(configuration.preferredVideoStabilizationMode)

        #if !os(macOS)
            if configuration.enableMultitaskingCameraAccess {
                if session.isMultitaskingCameraAccessSupported {
                    session.isMultitaskingCameraAccessEnabled = true
                } else {
                    PRMLogger.session.info(
                        "Multitasking camera access requested but not supported on this device (iPad only)"
                    )
                }
            }
        #endif

        // Snapshot the format AVFoundation landed on so `applyLivePhotoCompatibleFormat`
        // can restore it verbatim later. We capture AFTER all attachments + preferred-
        // format application so the snapshot reflects the format the user will actually
        // see rendering, not an intermediate state.
        baselineActiveFormat = videoDevice?.activeFormat

        if let device = videoDevice {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            PRMLogger.trace(
                .session,
                "configure complete: device=\(device.localizedName), activeFormat=\(dims.width)×\(dims.height)"
            )
        }
    }

    private func applyPreferredStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        if let connection = videoDataOutput?.connection(with: .video) {
            connection.prm_setStabilization(mode)
        }
        if let connection = movieFileOutput?.connection(with: .video) {
            connection.prm_setStabilization(mode)
        }
    }

    /// Removes every input and output the session previously held and nils out the
    /// cached handles so a follow-up `configure(_:)` starts from a clean slate. Called
    /// inside `configure` while a `beginConfiguration`/`commitConfiguration` block is
    /// open — AVFoundation batches the removals + the subsequent additions into a
    /// single session commit, so the user doesn't see a transient empty preview.
    private func tearDownAttachments() {
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoDeviceInput = nil
        videoDevice = nil
        audioDeviceInput = nil
        photoOutput = nil
        videoDataOutput = nil
        movieFileOutput = nil
    }

    // MARK: - Lifecycle

    /// Starts the session. Idempotent.
    public func start() {
        guard !isRunning else { return }
        PRMLogger.trace(.session, "start")
        session.startRunning()
        isRunning = session.isRunning
        PRMLogger.trace(.session, "start: isRunning=\(isRunning)")
    }

    /// Stops the session. Idempotent.
    public func stop() {
        guard isRunning else { return }
        PRMLogger.trace(.session, "stop")
        session.stopRunning()
        isRunning = false
    }

    // MARK: - Photo output readiness

    #if !os(macOS)
        /// Async-polls `AVCapturePhotoOutput.captureReadiness` until it reaches `.ready`
        /// (and the video connection is `isActive` AND `isEnabled`) OR the deadline
        /// elapses. Returns `true` when the output is ready, `false` on timeout.
        ///
        /// **Why session-level polling is necessary in addition to the per-capture poll
        /// in `PRMPhotoCapture`:** AVFoundation's post-`commitConfiguration` async pipeline
        /// rebuild on virtual devices (Triple / Dual / DualWide) can take 2-3 seconds —
        /// well beyond what's reasonable to block inside a `capturePhoto` call. When the
        /// consuming app fires multiple session mutations in quick succession
        /// (e.g. `switchDevice` followed by `setMovieFileOutputAttached` and
        /// `setLivePhotoCaptureEnabled` in the same mode-change handler), the *second*
        /// mutation lands while AVF is still rebuilding from the first, which on Triple
        /// Camera leaves `captureReadiness` permanently stuck at `.notReadyMomentarily`
        /// until something else jolts the pipeline. Awaiting readiness at the END of
        /// `switchDevice` / `switchCamera` blocks the consuming app from issuing
        /// follow-up mutations until AVF has finished — single-stepping the rebuild
        /// stack instead of letting it stack up.
        ///
        /// Per WWDC23 session 10105, `captureReadiness` is Apple's documented signal
        /// for "photo output rebuild is finished." `AVCapturePhotoOutputReadinessCoordinator`
        /// is the delegate-driven equivalent; we poll the bare property to avoid the
        /// extra MainActor-isolated delegate plumbing.
        ///
        /// - Parameters:
        ///   - timeout: Maximum wait in seconds. 3 s is the empirically-observed
        ///     ceiling for Triple-Camera-after-Wide rebuilds on iPhone 15 Pro Max;
        ///     longer waits are tolerable since this only runs after explicit user
        ///     actions (mode switches, device hops).
        ///   - pollIntervalMS: Poll cadence. Default 50 ms — fast enough to add no
        ///     perceptible delay when readiness is immediate (common case), slow
        ///     enough to not hammer the actor.
        /// - Returns: `true` on ready, `false` on timeout.
        @discardableResult
        public func awaitPhotoOutputReady(timeout: TimeInterval = 3.0, pollIntervalMS: UInt64 = 50) async -> Bool {
            // Short-circuit when the photo output is intentionally detached
            // (e.g. slo-mo workflow that dropped it for the ISP budget). No
            // photo output means nothing to wait for — return `true` so callers
            // can proceed without a 3 s timeout warning.
            guard photoOutput != nil else {
                PRMLogger.trace(.session, "awaitPhotoOutputReady: photo output detached, skipping wait")
                return true
            }
            let pollStep: UInt64 = pollIntervalMS * 1_000_000
            let startedAt = Date()
            let deadline = startedAt.addingTimeInterval(timeout)
            while Date() < deadline {
                if let output = photoOutput {
                    let connection = output.connection(with: .video)
                    let connectionReady = connection?.isEnabled == true && connection?.isActive == true
                    // **`maxPhotoDimensions != (0, 0)` is the reliable readiness signal**,
                    // NOT `captureReadiness`. Per WWDC23 session 10105, `captureReadiness`
                    // only flips to `.notReadyMomentarily` AFTER a `capturePhoto` request
                    // has been enqueued — so before any capture call, it always reads
                    // `.ready` regardless of internal pipeline rebuild state. By contrast,
                    // `maxPhotoDimensions` is reset to `(0, 0)` by the rebuild and only
                    // populated when AVF finishes re-validating the photo output against
                    // the current `activeFormat`. Gating on both gives us a sound
                    // "is the photo output usable right now" check.
                    let dims = output.maxPhotoDimensions
                    let dimsReady = dims.width > 0 && dims.height > 0
                    if connectionReady, dimsReady, output.captureReadiness == .ready {
                        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                        PRMLogger.trace(
                            .session,
                            "awaitPhotoOutputReady: ready after \(elapsedMS) ms (maxDim=\(dims.width)×\(dims.height))"
                        )
                        return true
                    }
                    // If the connection is back but maxDim is stuck at 0×0, try to heal
                    // by re-applying the ceiling from the active format. Same trick the
                    // per-capture pre-flight uses; we run it here so subsequent reads
                    // during the same poll loop see the re-applied value and exit early.
                    if connectionReady, !dimsReady, let device = videoDevice {
                        let supported = device.activeFormat.supportedMaxPhotoDimensions
                            .filter { $0.width >= $0.height }
                        if let largest = supported.max(by: {
                            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                        }) {
                            output.maxPhotoDimensions = largest
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: pollStep)
            }
            let readinessText = photoOutput?.captureReadiness.rawValue.description ?? "nil"
            let connectionText = photoOutput?.connection(with: .video) != nil ? "present" : "nil"
            let dimsText = if let dims = photoOutput?.maxPhotoDimensions {
                "\(dims.width)×\(dims.height)"
            } else {
                "nil"
            }
            PRMLogger.session.warning(
                """
                awaitPhotoOutputReady: timeout after \(Int(timeout * 1000), privacy: .public) ms — \
                readiness=\(readinessText, privacy: .public), connection=\(connectionText, privacy: .public), \
                maxDim=\(dimsText, privacy: .public)
                """
            )
            return false
        }
    #endif

    // MARK: - Camera switching

    /// Switches the video input to the best device at the given position, using the
    /// configuration's `deviceTypes` priority list. Returns the new device.
    @discardableResult
    public func switchCamera(to position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        guard let configuration else {
            throw PRMSessionError.cannotAttachToSession("Session not yet configured")
        }
        guard let newDevice = Self.bestVideoDevice(
            position: position,
            types: configuration.deviceTypes
        ) else {
            throw PRMSessionError.noVideoDevice(position)
        }
        try swapInput(to: newDevice)
        return newDevice
    }

    /// Switches the video input to a specific device type, keeping the current camera
    /// position (or moving to `position` if specified). Returns the new device.
    ///
    /// Use this when the application needs a physical device handle that the current
    /// virtual device doesn't expose — most commonly the wide camera for slo-mo on
    /// iPhone Pro models, whose `.builtInTripleCamera` virtual device's `formats` list
    /// excludes the 120/240 fps formats that exist on `.builtInWideAngleCamera`.
    ///
    /// ```swift
    /// // Hop to the physical wide camera for slo-mo:
    /// let wide = try await session.switchDevice(type: .builtInWideAngleCamera)
    /// try await device.prm_setFrameRate(240)
    ///
    /// // Hop back to the triple camera:
    /// let triple = try await session.switchDevice(type: .builtInTripleCamera)
    /// ```
    ///
    /// No-ops if the current device already matches the requested type *and* position.
    @discardableResult
    public func switchDevice(
        type: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position? = nil
    ) throws -> AVCaptureDevice {
        let targetPosition = position ?? videoDevice?.position ?? .back
        if let current = videoDevice, current.deviceType == type, current.position == targetPosition {
            return current
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [type],
            mediaType: .video,
            position: targetPosition
        )
        guard let newDevice = discovery.devices.first else {
            throw PRMSessionError.noDeviceOfType(type, targetPosition)
        }
        try swapInput(to: newDevice)
        return newDevice
    }

    /// Removes the current video input (if any) and installs an input wrapping `newDevice`.
    /// Wrapped in `beginConfiguration`/`commitConfiguration` so the session can stay running
    /// across the swap. Restores the original input on failure so the session is never left
    /// without a video input.
    private func swapInput(to newDevice: AVCaptureDevice) throws {
        guard let currentInput = videoDeviceInput else {
            throw PRMSessionError.cannotAttachToSession("No current input to swap")
        }
        PRMLogger.trace(
            .session,
            "swapInput: \(videoDevice?.localizedName ?? "nil") → \(newDevice.localizedName) (type=\(newDevice.deviceType.rawValue), pos=\(newDevice.position.rawValue))"
        )
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: newDevice)
        } catch {
            throw PRMSessionError.cannotCreateDeviceInput(error.localizedDescription)
        }

        // Reset the OUTGOING device's frame-duration constraints BEFORE removing it.
        // AVCaptureDevice properties (including `activeVideoMinFrameDuration` /
        // `activeVideoMaxFrameDuration`) persist on the device instance across input
        // swap-outs. If the user just exited a slo-mo workflow at 240 fps on the
        // wide camera and the app now hops back to the triple camera, the wide
        // camera retains the 1/240 duration — and if the user later hops back to
        // wide (e.g. for the Max Dimensions toggle, depth, etc.), AVF tries to
        // build the photo output's connection against the leftover 240 fps state
        // and fails silently (output.connection(with: .video) returns nil,
        // output.maxPhotoDimensions reads (0,0)). Pre-emptive cleanup here is
        // cheap and keeps the device in a clean state for the next time it's
        // active in the session.
        if let outgoingDevice = videoDevice {
            try? outgoingDevice.prm_resetFrameRate()
        }

        session.beginConfiguration()
        session.removeInput(currentInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoDeviceInput = newInput
            videoDevice = newDevice
        } else {
            // Fall back to original input — keep session usable.
            session.addInput(currentInput)
            session.commitConfiguration()
            throw PRMSessionError.cannotAttachToSession("Cannot attach \(newDevice.localizedName)")
        }
        // Also reset the INCOMING device's frame-duration. It may carry forward
        // leftover state from its own prior session usage (e.g. swap back to a
        // device that was previously set to a custom frame duration).
        try? newDevice.prm_resetFrameRate()

        #if !os(macOS)
            // New device may have a different `formats` list (e.g. virtual → physical wide
            // unlocks the 48MP-capable format). Re-pick the preferred format and re-raise
            // the photo output's max-dimensions ceiling to match.
            applyPreferredPhotoFormatIfNeeded()
            refreshOutputMaxPhotoDimensions()
            // Re-assert the photo output's aux delivery flags against the new input.
            // Per Apple's AVCam reference: "When changing cameras, the
            // livePhotoCaptureEnabled and depthDataDeliveryEnabled properties of the
            // AVCapturePhotoOutput gets set to NO when a video device is disconnected
            // from the session. After the new video device is added to the session,
            // re-enable them on the AVCapturePhotoOutput if it is supported." We
            // honor that pattern instead of detaching/reattaching the whole output —
            // a full reattach against the destination input doesn't reliably restore
            // `isLivePhotoCaptureSupported` on virtual devices (Triple/Dual), but the
            // AVCam-style in-place re-set does because the support flag re-reads from
            // the new connection chain on the existing output instance.
            if let photoOutput, let configuration {
                if configuration.enableLivePhoto {
                    photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
                }
                if configuration.enableDepthDataDelivery {
                    photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
                }
                if configuration.enablePortraitEffectsMatteDelivery {
                    photoOutput.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliverySupported
                }
                PRMLogger.trace(
                    .session,
                    "swapInput post: live(supported=\(photoOutput.isLivePhotoCaptureSupported), enabled=\(photoOutput.isLivePhotoCaptureEnabled))"
                )
            }
        #endif
        session.commitConfiguration()

        #if !os(macOS)
            // **Fallback: full session reconfigure when Live Photo support didn't survive
            // the swap.** AVCam's in-place re-set works for some device transitions
            // (Triple → Wide) but fails for others (Wide → Triple): on virtual devices,
            // the photo output's secondary movie pipeline doesn't re-bind to the new
            // input even with the AVCam-style flag re-assert. Empirically the *only*
            // path that reliably restores `isLivePhotoCaptureSupported` on Triple after
            // a Wide round-trip is the same path that worked at boot: tear down every
            // attachment and re-run the full configure flow.
            //
            // This is expensive (300+ ms preview freeze) and we'd prefer not to do it,
            // but: (a) the user explicitly asked us to prioritize making this work over
            // staying clever; (b) it only fires when Live Photo was requested AND the
            // in-place re-set failed — the common case (Live Photo off, or in-place
            // succeeded) is unaffected. The reconfigure preserves the destination
            // device since `videoDevice` is already updated above.
            if let configuration, configuration.enableLivePhoto, let photoOutput,
               !photoOutput.isLivePhotoCaptureSupported {
                PRMLogger.session.notice(
                    "swapInput: Live Photo lost on \(newDevice.localizedName, privacy: .public) — full session reconfigure"
                )
                // Snapshot the **dynamic** state that `tearDownAttachments()` is about
                // to wipe — `reconfigureForDevice` would otherwise rebuild only against
                // the original `PRMCameraConfiguration`, dropping runtime mutations like
                // `setMovieFileOutputAttached(true)` (entered when the consuming app
                // switched to a video / slo-mo mode) and the per-runtime Live-Photo
                // enable flag. Re-applied after the rebuild below so post-reconfigure
                // captures keep working.
                let dynamicState = DynamicSessionState(
                    movieFileOutputAttached: movieFileOutput != nil,
                    livePhotoCaptureEnabled: photoOutput.isLivePhotoCaptureEnabled
                )
                try reconfigureForDevice(newDevice, configuration: configuration, dynamicOverride: dynamicState)
            }
        #endif

        // Re-snapshot the baseline format for the new device so a subsequent
        // `applyLivePhotoCompatibleFormat()` restores to THIS device's known-good
        // default, not a stale snapshot from the prior device.
        baselineActiveFormat = videoDevice?.activeFormat ?? newDevice.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions((videoDevice ?? newDevice).activeFormat.formatDescription)
        PRMLogger.trace(
            .session,
            "swapInput complete: device=\((videoDevice ?? newDevice).localizedName), activeFormat=\(dims.width)×\(dims.height)"
        )
    }

    #if !os(macOS)
        /// Full session tear-down + rebuild against a specific destination device,
        /// reusing the original `PRMCameraConfiguration` shape (audio / video / photo
        /// / movie attachments, enableLivePhoto, depth, etc.). Used as a last-resort
        /// recovery from `swapInput` when the in-place flag re-assert can't restore
        /// `isLivePhotoCaptureSupported` on virtual devices (see swapInput comment).
        ///
        /// Mirrors `configure(_:)`'s attach order: video input → preferred format →
        /// audio → video data output → photo output → movie output. The destination
        /// device is forced via a direct `AVCaptureDeviceInput(device:)` instead of
        /// going through `attachVideoDevice` (which would re-run device discovery and
        /// could pick a different device).
        private func reconfigureForDevice(
            _ device: AVCaptureDevice,
            configuration: PRMCameraConfiguration,
            dynamicOverride: DynamicSessionState? = nil
        ) throws {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            tearDownAttachments()
            session.sessionPreset = configuration.sessionPreset
            configuredSessionPreset = configuration.sessionPreset

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                throw PRMSessionError.cannotCreateDeviceInput(error.localizedDescription)
            }
            guard session.canAddInput(input) else {
                throw PRMSessionError.cannotAttachToSession("Cannot add video input during reconfigure")
            }
            session.addInput(input)
            videoDeviceInput = input
            videoDevice = device

            // Reset the destination device's frame-duration constraints. The device
            // may carry forward a leftover `activeVideoMinFrameDuration` /
            // `activeVideoMaxFrameDuration` from a prior session in this process —
            // e.g. the user just exited a slo-mo workflow that called
            // `prm_setFrameRate(240)` on the wide camera, hopped to the triple
            // camera, and the triple camera's instance still has those durations
            // pinned because AVCaptureDevice properties persist across input
            // swap-outs.
            //
            // Without this reset, `attachPhotoOutput` adds the output cleanly but
            // its video connection can't be validated against the leftover frame
            // duration — `output.maxPhotoDimensions` then reads (0, 0) and
            // `output.connection(with: .video)` either returns `nil` or returns a
            // connection with `isActive == false`. The user-visible symptom is
            // every subsequent `capturePhoto` failing with "no active video
            // connection" until the consuming app explicitly calls
            // `resetFrameRate()` (which our reset here makes unnecessary).
            try? device.prm_resetFrameRate()

            applyPreferredPhotoFormatIfNeeded()

            if configuration.includesAudio {
                attachAudioDevice()
            }
            if configuration.includesVideoDataOutput {
                try attachVideoDataOutput(
                    pixelFormat: configuration.videoPixelFormat,
                    discardsLateVideoFrames: configuration.discardsLateVideoFrames
                )
            }
            if configuration.includesPhotoOutput {
                try attachPhotoOutput(configuration: configuration)
            }
            // Attach movie output ONLY when the caller asked for it via the dynamic
            // override (live state captured before the reconfigure) OR the original
            // configuration declared it. Without the override branch, the
            // post-reconfigure `setMovieFileOutputAttached(true)` runs as an extra
            // begin/commit cycle — one toggle too many on top of AVF's already-in-
            // flight Live-Photo rebuild, which on virtual devices can leave the
            // photo output's secondary movie pipeline permanently stuck in
            // `.notReadyMomentarily` (3 s+ unrecoverable, see the workspace lesson
            // catalog entry on isLivePhotoCaptureEnabled async re-validation).
            // Baking the dynamic state INTO this one begin/commit gives AVF a
            // single rebuild target instead of a stack of three.
            let shouldAttachMovie = dynamicOverride?.movieFileOutputAttached
                ?? configuration.includesMovieFileOutput
            if shouldAttachMovie {
                try attachMovieFileOutput()
            }
            // Same rationale for Live Photo: bake the requested enabled state
            // directly into the photo output's attach-time configuration, rather
            // than calling `setLivePhotoCaptureEnabled(_:)` afterwards in a fresh
            // begin/commit. `attachPhotoOutput` already honors
            // `configuration.enableLivePhoto`; if the runtime override differs,
            // overwrite IN-PLACE here (still inside this same begin/commit) and
            // call `refreshOutputMaxPhotoDimensions` to keep the ceiling consistent.
            // No extra session commit cycle, no async rebuild stack-up.
            #if !os(macOS)
                if let override = dynamicOverride, let photoOutput {
                    // Movie output presence forces Live Photo OFF (AVF documents this
                    // mutual exclusion). If the dynamic override asked for movie attached,
                    // Live Photo is already OFF and any explicit override is moot. When
                    // there's no movie attached, honor the captured Live Photo state.
                    let desiredLive = override.movieFileOutputAttached
                        ? false
                        : (override.livePhotoCaptureEnabled && photoOutput.isLivePhotoCaptureSupported)
                    if photoOutput.isLivePhotoCaptureEnabled != desiredLive {
                        photoOutput.isLivePhotoCaptureEnabled = desiredLive
                        refreshOutputMaxPhotoDimensions()
                    }
                }
            #endif
            applyPreferredStabilization(configuration.preferredVideoStabilizationMode)
            let supported = photoOutput?.isLivePhotoCaptureSupported ?? false
            let enabled = photoOutput?.isLivePhotoCaptureEnabled ?? false
            PRMLogger.trace(
                .session,
                "reconfigureForDevice complete: device=\(device.localizedName), live(supported=\(supported), enabled=\(enabled), movieAttached=\(movieFileOutput != nil))"
            )
        }

        /// Runtime-mutable session state that `reconfigureForDevice` would otherwise
        /// drop on the floor. The reconfigure rebuilds purely from the original
        /// `PRMCameraConfiguration` shape, so any mutation the consuming app applied
        /// at runtime — entering video mode (`setMovieFileOutputAttached(true)`),
        /// disabling Live Photo for a manual-exposure capture, etc. — has to be
        /// snapshotted before the teardown and re-applied after the rebuild.
        ///
        /// Without this round-trip the silent regression is severe: a
        /// PHOTO → SLO-MO → tap-record sequence (which round-trips Triple → Wide,
        /// fires the Live-Photo-lost reconfigure on Wide, and then taps record on
        /// the freshly-rebuilt session) throws `NSInvalidArgumentException` —
        /// `*** -[AVCaptureMovieFileOutput startRecordingToOutputFileURL:...] No
        /// active/enabled connections` — because the movie output the consuming app
        /// attached for video mode was wiped by `tearDownAttachments()` and never
        /// re-attached (the original configuration had `includesMovieFileOutput =
        /// false`).
        private struct DynamicSessionState {
            let movieFileOutputAttached: Bool
            let livePhotoCaptureEnabled: Bool
        }

    #endif

    // MARK: - Delegate installation

    /// Cached sample-buffer delegate so it can be re-installed after a full session
    /// reconfigure (which creates a fresh `videoDataOutput` instance and loses the
    /// delegate set on the prior instance). `nonisolated(unsafe)` because the only
    /// writers run on `PRMCameraActor` and the AVFoundation `setSampleBufferDelegate`
    /// docs are explicit that it can be called from any actor.
    private var cachedVideoDataOutputDelegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?

    /// Installs a sample-buffer delegate on the video data output. Cached so a
    /// full session reconfigure (e.g. the `swapInput` recovery path for Live Photo
    /// support on virtual devices) automatically re-installs it on the new output.
    public func setVideoDataOutputDelegate(
        _ delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
    ) {
        cachedVideoDataOutputDelegate = delegate
        videoDataOutput?.setSampleBufferDelegate(delegate, queue: dataOutputQueue)
    }

    // MARK: - Static device discovery

    /// Returns the best available device for the given position, scanning the type list in order.
    nonisolated static func bestVideoDevice(
        position: AVCaptureDevice.Position,
        types: [AVCaptureDevice.DeviceType]
    ) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    // MARK: - Private setup helpers

    private func attachVideoDevice(
        position: AVCaptureDevice.Position,
        types: [AVCaptureDevice.DeviceType]
    ) throws {
        guard let device = Self.bestVideoDevice(position: position, types: types) else {
            throw PRMSessionError.noVideoDevice(position)
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw PRMSessionError.cannotCreateDeviceInput(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw PRMSessionError.cannotAttachToSession("Cannot add video input")
        }
        session.addInput(input)
        videoDeviceInput = input
        videoDevice = device
    }

    private func attachAudioDevice() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        guard let audio = discovery.devices.first else {
            PRMLogger.session.warning("No microphone available; audio input skipped")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: audio)
        } catch {
            PRMLogger.session.warning(
                "Failed to create audio input: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard session.canAddInput(input) else {
            PRMLogger.session.warning("Cannot add audio input to session; skipping")
            return
        }
        session.addInput(input)
        audioDeviceInput = input
    }

    private func attachVideoDataOutput(pixelFormat: OSType, discardsLateVideoFrames: Bool) throws {
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.alwaysDiscardsLateVideoFrames = discardsLateVideoFrames
        guard session.canAddOutput(output) else {
            throw PRMSessionError.cannotAttachToSession("Cannot add video data output")
        }
        session.addOutput(output)
        videoDataOutput = output
        // Re-apply the cached delegate so a full reconfigure (which creates a fresh
        // output instance) doesn't strand the filter pipeline / preview view with no
        // frame source. The cache is populated by `setVideoDataOutputDelegate(_:)`.
        if let cachedVideoDataOutputDelegate {
            output.setSampleBufferDelegate(cachedVideoDataOutputDelegate, queue: dataOutputQueue)
        }
    }

    private func attachPhotoOutput(configuration: PRMCameraConfiguration) throws {
        let output = AVCapturePhotoOutput()
        output.maxPhotoQualityPrioritization = configuration.maxPhotoQualityPrioritization
        // `isLivePhotoCaptureSupported` / `isDepthDataDeliverySupported` / etc. are
        // session-configuration-aware: they only return meaningful values AFTER the
        // output has been added to a session with a video device. Querying them before
        // `addOutput` returns `false` for every feature, regardless of whether the
        // device actually supports it. So: add first, configure features second.
        guard session.canAddOutput(output) else {
            throw PRMSessionError.cannotAttachToSession("Cannot add photo output")
        }
        session.addOutput(output)
        photoOutput = output

        #if !os(macOS)
            refreshOutputMaxPhotoDimensions()

            applyPhotoOutputFeature(
                "Live Photo",
                requested: configuration.enableLivePhoto,
                supported: output.isLivePhotoCaptureSupported
            ) { output.isLivePhotoCaptureEnabled = true }
            applyPhotoOutputFeature(
                "Depth data delivery",
                requested: configuration.enableDepthDataDelivery,
                supported: output.isDepthDataDeliverySupported
            ) { output.isDepthDataDeliveryEnabled = true }
            applyPhotoOutputFeature(
                "Portrait effects matte",
                requested: configuration.enablePortraitEffectsMatteDelivery,
                supported: output.isPortraitEffectsMatteDeliverySupported
            ) { output.isPortraitEffectsMatteDeliveryEnabled = true }
            applyPhotoOutputFeature(
                "Responsive capture",
                requested: configuration.enableResponsiveCapture,
                supported: output.isResponsiveCaptureSupported
            ) { output.isResponsiveCaptureEnabled = true }
            applyPhotoOutputFeature(
                "Auto-deferred photo delivery",
                requested: configuration.enableAutoDeferredPhotoDelivery,
                supported: output.isAutoDeferredPhotoDeliverySupported
            ) { output.isAutoDeferredPhotoDeliveryEnabled = true }
            applyPhotoOutputFeature(
                "Zero shutter lag",
                requested: configuration.enableZeroShutterLag,
                supported: output.isZeroShutterLagSupported
            ) { output.isZeroShutterLagEnabled = true }
        #endif
    }

    private func applyPhotoOutputFeature(
        _ name: String,
        requested: Bool,
        supported: Bool,
        apply: () -> Void
    ) {
        guard requested else { return }
        guard supported else {
            PRMLogger.session.info("\(name, privacy: .public) requested but not supported on this device")
            return
        }
        apply()
    }

    // Format-management methods (refreshOutputMaxPhotoDimensions, applyAuxiliaryPhotoOutputFlags,
    // applyHighResolutionPhotoFormat, applyLivePhotoCompatibleFormat, applyPreferredPhotoFormatIfNeeded,
    // applyPhotoFormat, scored-candidate helpers) live in `PRMCameraSession+Format.swift`. They
    // were extracted to keep this file focused on session lifecycle (configure, start/stop,
    // switch, attach/detach). See that file's header comment for the rationale.

    private func attachMovieFileOutput() throws {
        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw PRMSessionError.cannotAttachToSession("Cannot add movie file output")
        }
        session.addOutput(output)
        movieFileOutput = output
    }

    // MARK: - Live Photo / movie-output mutual exclusion

    /// Dynamically attach or detach `AVCaptureMovieFileOutput`. Use this to switch the
    /// session between *video-recording mode* (movie output attached, Live Photo
    /// unavailable) and *Live-Photo-capable mode* (movie output detached, Live Photo
    /// re-enabled if supported).
    ///
    /// `AVCapturePhotoOutput.isLivePhotoCaptureSupported` returns `false` whenever
    /// `AVCaptureMovieFileOutput` is also in the session — Apple documents the two as
    /// mutually exclusive. Apps that want both modes have to reconfigure when crossing
    /// between them; this is the same trade-off the built-in Camera app makes.
    ///
    /// Wrapped in `beginConfiguration` / `commitConfiguration` so the session can stay
    /// running. The reconfigure typically takes 50-300 ms on real hardware.
    /// Runtime toggle for `AVCapturePhotoOutput.isLivePhotoCaptureEnabled`. Off by default
    /// after `configure(_:)` honors the initial `PRMCameraConfiguration.enableLivePhoto`
    /// flag; callers flip this to opt into / out of Live Photo capability per-frame.
    ///
    /// Live Photo capability **interferes with manual exposure (custom mode) and WB lock**:
    /// on iPhone, AVFoundation will silently revert `device.exposureMode = .custom` back
    /// to a continuous-auto path within a frame or two if the photo output is still
    /// advertising Live Photo. Studio-style apps that expose manual sliders need to flip
    /// this off whenever the user enters Custom / Locked, and back on only when staying in
    /// Live Photo mode with auto exposure.
    ///
    /// Wrapped in `beginConfiguration`/`commitConfiguration` so the change lands atomically.
    /// No-op if Live Photo is not supported on this device / session combo, or if the
    /// requested state is already in effect.
    public func setLivePhotoCaptureEnabled(_ enabled: Bool) {
        #if !os(macOS)
            guard let photoOutput else {
                PRMLogger.session.error("setLivePhotoCaptureEnabled(\(enabled, privacy: .public)): no photoOutput attached")
                return
            }
            // **`isLivePhotoCaptureSupported` is a build-time property of the pipeline,
            // not a runtime one.** Per Apple's docs
            // (developer.apple.com/documentation/avfoundation/avcapturephotooutput/
            // islivephotocapturesupported): "Live Photo capture requires a lengthy
            // reconfiguration of the capture render pipeline, so if you intend to do any
            // Live Photo captures at all, you should set livePhotoCaptureEnabled to YES
            // *before calling -[AVCaptureSession startRunning]*." If the session was
            // configured with `PRMCameraConfiguration.enableLivePhoto = false`, the
            // secondary movie-capture path was never wired into the pipeline and no
            // amount of format swapping or output reconfiguration can add it after the
            // fact (verified empirically: iterating all 12 formats on Triple camera with
            // a Live-Photo-disabled pipeline produces `isLivePhotoCaptureSupported=false`
            // on every single one).
            //
            // So the error here is a configuration-time bug in the consuming app, not a
            // runtime-recoverable state. The log message points the user at the fix
            // instead of silently no-op'ing or thrashing the active format.
            if enabled, !photoOutput.isLivePhotoCaptureSupported {
                PRMLogger.session.error(
                    """
                    setLivePhotoCaptureEnabled(true): isLivePhotoCaptureSupported=false. \
                    The session was configured with enableLivePhoto=false. Live Photo \
                    pipeline support is decided at configure time and cannot be added \
                    at runtime — set PRMCameraConfiguration.enableLivePhoto=true before \
                    calling camera.configure(_:).
                    """
                )
                return
            }
            guard photoOutput.isLivePhotoCaptureEnabled != enabled else {
                PRMLogger.session.debug(
                    "setLivePhotoCaptureEnabled(\(enabled, privacy: .public)): already \(enabled, privacy: .public), no-op"
                )
                return
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            photoOutput.isLivePhotoCaptureEnabled = enabled
            // Toggling `isLivePhotoCaptureEnabled` reconfigures the photo output's
            // secondary movie pipeline, which AVFoundation accomplishes by resetting
            // the output's per-format ceilings — including `maxPhotoDimensions` to
            // (0, 0) — and transiently invalidating `output.connection(with: .video)`.
            // Apple's docs describe the toggle as requiring "a lengthy reconfiguration
            // of the capture render pipeline"; the side-effect on `maxPhotoDimensions`
            // is undocumented but reproducible on virtual devices (Triple/Dual). On
            // iPhone Pro models, the symptom is the NEXT `capturePhoto` reading
            // `output.maxPhotoDimensions == (0, 0)` and `output.connection(with: .video)
            //  == nil`, which our pre-flight guard then turns into a typed Swift error
            // instead of an uncaught `NSInvalidArgumentException`. Re-applying the
            // ceiling against the current `activeFormat` (and inside the SAME session
            // commit so AVF re-validates atomically) restores `maxPhotoDimensions` and
            // the video connection in one pass.
            refreshOutputMaxPhotoDimensions()
            PRMLogger.session.notice(
                "setLivePhotoCaptureEnabled: now \(enabled, privacy: .public)"
            )
        #endif
    }

    /// Toggle the photo output's attachment to the session. Use this to drop the
    /// photo output entirely when entering a workflow that doesn't need stills AND
    /// is bumping into the ISP hardware budget (`AVError -11872 "Cannot Record"
    /// — Too many camera hardware resources were requested"`).
    ///
    /// The canonical example is 240 fps slo-mo on physical Wide camera with movie
    /// output attached: AVF computes the photo output's secondary movie pipeline
    /// + video data output + movie output + 240 fps frame rate as exceeding the
    /// ISP bandwidth limit (per [WWDC19 session 249 — Multi-Camera Capture for
    /// iOS](https://developer.apple.com/videos/play/wwdc2019/249/): *"the ISP
    /// bandwidth limit is hard"*). The error surfaces via
    /// `AVCaptureSessionRuntimeErrorNotification` even though recording still
    /// succeeds in degraded form. Apple's own Camera app drops the photo output
    /// for slo-mo entry — slo-mo never offers Live Photo for exactly this reason.
    ///
    /// On re-attach, the photo output is rebuilt from the original
    /// `PRMCameraConfiguration` (Live Photo / depth / matte / responsive-capture /
    /// auto-deferred / ZSL flags). Consuming apps must rebuild any cached
    /// `PRMPhotoCapture` wrapper after re-attach because the new instance is a
    /// fresh `AVCapturePhotoOutput` (see the workspace lesson catalog entry on
    /// stale output references).
    ///
    /// No-op when the requested state already matches. Throws if `attach: true`
    /// fails (e.g. the session refuses `canAddOutput` — usually a sign of
    /// hardware budget overrun in the opposite direction).
    public func setPhotoOutputAttached(_ attached: Bool) throws {
        PRMLogger.trace(.session, "setPhotoOutputAttached(\(attached)): current=\(photoOutput != nil)")
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if attached {
            guard photoOutput == nil, let configuration else { return }
            try attachPhotoOutput(configuration: configuration)
        } else {
            guard let photoOutput else { return }
            session.removeOutput(photoOutput)
            self.photoOutput = nil
        }
    }

    /// Toggle the movie file output between attached (video recording capable) and
    /// detached (Live Photo capable) state, optionally with an explicit Live Photo
    /// state to apply IN THE SAME begin/commit.
    ///
    /// **Why `targetLivePhoto:` matters**: AVFoundation's documented behavior
    /// (per [`isLivePhotoCaptureEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/islivephotocaptureenabled)
    /// docs) is that toggling Live Photo requires "a lengthy reconfiguration of the
    /// capture render pipeline." On virtual devices (Triple/Dual/DualWide), each
    /// toggle invalidates the photo output's video connection and resets
    /// `maxPhotoDimensions` to `(0, 0)` for 2-3 seconds. If a caller fires
    /// `setMovieFileOutputAttached(false)` then `setLivePhotoCaptureEnabled(false)`
    /// in quick succession (a common pattern for "enter a non-Live-Photo photo mode
    /// like NIGHT"), the detach's mutual-exclusion side-effect first re-enables
    /// Live Photo, then the explicit setter immediately toggles it back to false —
    /// **two toggles back-to-back** in adjacent begin/commit cycles, leaving the
    /// secondary movie pipeline stranded.
    ///
    /// Passing `targetLivePhoto:` lets the caller bake the desired Live Photo state
    /// directly into this method's single begin/commit, avoiding the second toggle.
    /// When omitted (`nil`), behavior matches the legacy single-arg form: detaching
    /// re-enables Live Photo per `configuration.enableLivePhoto`; attaching forces
    /// Live Photo OFF per AVF's mutual exclusion.
    ///
    /// - Parameter attached: Whether the movie output should be attached afterwards.
    /// - Parameter targetLivePhoto: Optional explicit Live Photo state to apply
    ///   in the same begin/commit. When set with `attached: true`, must be `false`
    ///   (mutual exclusion); passing `true` is silently coerced to `false` to
    ///   preserve the AVF invariant. When omitted, the method picks a default per
    ///   the legacy behavior described above.
    public func setMovieFileOutputAttached(_ attached: Bool, targetLivePhoto: Bool? = nil) throws {
        PRMLogger.trace(
            .session,
            "setMovieFileOutputAttached(\(attached), targetLivePhoto=\(targetLivePhoto.map(String.init(describing:)) ?? "nil")): current=\(movieFileOutput != nil)"
        )
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if attached {
            if movieFileOutput == nil {
                try attachMovieFileOutput()
            }
            // Movie output and Live Photo are mutually exclusive per AVF — force OFF.
            #if !os(macOS)
                if let photoOutput, photoOutput.isLivePhotoCaptureEnabled {
                    photoOutput.isLivePhotoCaptureEnabled = false
                    refreshOutputMaxPhotoDimensions()
                }
            #endif
        } else {
            if let movieFileOutput {
                session.removeOutput(movieFileOutput)
                self.movieFileOutput = nil
            }
            #if !os(macOS)
                guard let photoOutput, let configuration, configuration.enableLivePhoto else { return }
                // Pick the final Live Photo state: explicit override wins; otherwise
                // default to the configuration's Live Photo intent (legacy behavior).
                let desiredLive = targetLivePhoto ?? configuration.enableLivePhoto
                let finalLive = desiredLive && photoOutput.isLivePhotoCaptureSupported
                if photoOutput.isLivePhotoCaptureEnabled != finalLive {
                    photoOutput.isLivePhotoCaptureEnabled = finalLive
                    refreshOutputMaxPhotoDimensions()
                }
            #endif
        }
    }
}
