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
        self.configuration = configuration

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        tearDownAttachments()

        session.sessionPreset = configuration.sessionPreset

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
        session.startRunning()
        isRunning = session.isRunning
    }

    /// Stops the session. Idempotent.
    public func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

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
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: newDevice)
        } catch {
            throw PRMSessionError.cannotCreateDeviceInput(error.localizedDescription)
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
        #if !os(macOS)
            // New device may have a different `formats` list (e.g. virtual → physical wide
            // unlocks the 48MP-capable format). Re-pick the preferred format and re-raise
            // the photo output's max-dimensions ceiling to match.
            applyPreferredPhotoFormatIfNeeded()
            refreshOutputMaxPhotoDimensions()
        #endif
        session.commitConfiguration()
    }

    // MARK: - Delegate installation

    /// Installs a sample-buffer delegate on the video data output.
    public func setVideoDataOutputDelegate(
        _ delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
    ) {
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

    #if !os(macOS)
        /// Sets `output.maxPhotoDimensions` to the largest entry the current device's
        /// active format supports. Without this, per-photo `maxPhotoDimensions` requests
        /// for entries larger than AVFoundation's conservative default ceiling (typically
        /// the 12MP entry) throw `NSInvalidArgumentException` ("must not be larger than
        /// the maxPhotoDimensions set on the AVCapturePhotoOutput").
        ///
        /// Called at photo output attach AND again after every `swapInput` so the
        /// ceiling tracks the device's actual capability across virtual ↔ physical
        /// camera swaps (e.g. triple → wide for manual exposure or 48MP capture).
        private func refreshOutputMaxPhotoDimensions() {
            guard let output = photoOutput, let device = videoDevice else { return }
            // Same landscape filter as `applyPreferredPhotoFormatIfNeeded` — portrait
            // entries from video formats would otherwise win an area-based pick on iPhone
            // 15 Pro Max and pin the output ceiling to a 12MP video resolution.
            let supported = device.activeFormat.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
            guard let largest = supported.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else { return }
            output.maxPhotoDimensions = largest
        }

        /// If `prefersMaxPhotoDimensionsFormat` is set, swap `activeFormat` to the device
        /// format with the largest `supportedMaxPhotoDimensions` area. The `.photo` preset
        /// defaults to a conservative format (typically 12MP) even on iPhone 14 Pro+ /
        /// 15 Pro+ where the wide camera physically supports 48MP. Must run BEFORE
        /// `refreshOutputMaxPhotoDimensions` so the output ceiling pins against the
        /// promoted format.
        ///
        /// Pair the configuration flag with `deviceTypes: [.builtInWideAngleCamera]` —
        /// virtual devices (`triple`, `dual`, `dualWide`) cap at 12MP regardless of the
        /// format chosen, so this helper is a no-op on those.
        private func applyPreferredPhotoFormatIfNeeded() {
            guard configuration?.prefersMaxPhotoDimensionsFormat == true else { return }
            applyHighResolutionPhotoFormat()
        }

        /// Promotes `activeFormat` to the device format with the largest landscape
        /// `supportedMaxPhotoDimensions`. Filters to landscape (`width >= height`)
        /// entries — some video formats expose portrait dimensions (e.g. `(3024, 4032)`)
        /// that would otherwise outrank the true 48MP photo format by area on iPhone
        /// 15 Pro Max. **Incompatible with Live Photo / burst / depth streaming** —
        /// call `applyLivePhotoCompatibleFormat()` before re-enabling those.
        ///
        /// Per the workspace AVFoundation lesson catalog and Apple dev-forum 715452 /
        /// 748321, 48MP capture requires the photo output's auxiliary delivery flags
        /// (Live Photo, depth, portrait matte) to be OFF — these all substitute 12MP
        /// proxy captures regardless of the active format. This helper turns them off
        /// inside the same session commit as the format swap so AVFoundation never
        /// sees a "48MP format + depth enabled" transient that would either reject
        /// the swap or downgrade captures to a tiny preview frame.
        func applyHighResolutionPhotoFormat() {
            applyPhotoFormat(name: "max-dimensions", maxAreaCeiling: nil, highRes: true)
        }

        /// Restores `activeFormat` to a Live-Photo-compatible format. The 48MP photo
        /// format doesn't stream the parallel movie pipeline Live Photo needs, so
        /// callers must reset before enabling Live Photo, burst, or depth capture.
        /// Picks the largest-resolution format whose dimensions stay at or below 20MP
        /// (the boundary that separates 12MP video-streaming formats from the 48MP
        /// pure-photo format across iPhone Pro models).
        ///
        /// **Restores** the auxiliary delivery flags (Live Photo / depth / portrait
        /// matte) per the original `PRMCameraConfiguration` so toggling Max Dimensions
        /// off recovers the pre-toggle capture pipeline. Without this restore, the
        /// flags stay off from the high-res toggle and subsequent captures lose
        /// depth/matte ancillaries that the app explicitly configured at startup —
        /// AND, more visibly, the output's `maxPhotoDimensions` stays pinned at the
        /// 48MP ceiling from the toggle-on path, which fights AVFoundation's per-photo
        /// validation against the now-smaller `activeFormat` and degrades the saved
        /// photo to a 144×192 preview proxy. This is the "toggle off, photo comes
        /// back tiny" symptom.
        func applyLivePhotoCompatibleFormat() {
            applyPhotoFormat(name: "Live-Photo-compatible", maxAreaCeiling: 20_000_000, highRes: false)
        }

        /// Shared format-swap path for the high-res / Live-Photo-compatible toggles.
        /// Critical detail: the format swap MUST be wrapped in
        /// `session.beginConfiguration()` / `commitConfiguration()`, not just the
        /// device-level `lockForConfiguration()`. Without the session wrap:
        ///
        /// 1. `device.activeFormat = best` updates the device immediately.
        /// 2. `output.maxPhotoDimensions = largest` is then validated by AVFoundation
        ///    against the SESSION's view of the active format — which is still the
        ///    pre-swap format until the next session commit. The assignment is
        ///    silently clamped to the OLD format's ceiling (typically 12MP).
        /// 3. Subsequent per-photo `settings.maxPhotoDimensions = largest` reads the
        ///    already-clamped output value, requesting (4032, 3024). The 48MP capture
        ///    you toggled on never actually fires — the saved photo stays at 12MP
        ///    with no error surfaced. This is the "Max Dimensions toggle does
        ///    nothing" symptom.
        ///
        /// Wrapping the format swap AND the output-ceiling refresh in a single
        /// session begin/commit forces AVFoundation to re-validate the photo output
        /// against the new active format before the assignment lands, so the 48MP
        /// ceiling sticks.
        ///
        /// Same pattern as `PRMCamera.enableDepthFormat()` — the photo output's
        /// delivery flags re-validate at session commit time, not at device-unlock
        /// time.
        ///
        /// - Parameters:
        ///   - name: Human-readable name for log lines on failure.
        ///   - maxAreaCeiling: When non-nil, only formats whose max landscape area
        ///     is ≤ this value are eligible (used to exclude the 48MP pure-photo
        ///     format from the Live-Photo-compatible path).
        ///   - highRes: `true` for the 48MP path — disables Live Photo / depth /
        ///     portrait matte on the photo output inside the same session commit so
        ///     AVFoundation never sees a 48MP-format + aux-flags-on transient (which
        ///     would either reject the swap or downgrade captures to a 144×192 preview
        ///     proxy). `false` for the Live-Photo-compatible path — restores the
        ///     aux flags from the original `PRMCameraConfiguration` so the toggle-off
        ///     direction recovers depth/matte/Live Photo support.
        private func applyPhotoFormat(name: String, maxAreaCeiling: Int64?, highRes: Bool) {
            guard let device = videoDevice else { return }
            func score(_ format: AVCaptureDevice.Format) -> Int64 {
                format.supportedMaxPhotoDimensions
                    .filter { $0.width >= $0.height }
                    .map { Int64($0.width) * Int64($0.height) }
                    .max() ?? 0
            }
            /// True dedicated photo format: max frame rate ≤ 30 (video formats can reach
            /// 60/120/240). Used as a tie-breaker so when multiple formats advertise the
            /// 48MP entry, we pick the pure-photo one over a video-streaming format that
            /// happens to list 48MP. iPhone 14 Pro+ / 15 Pro+ wide cameras both have
            /// exactly one such photo format with the 48MP entry — picking a video format
            /// by accident produces captures AVFoundation silently degrades to a preview
            /// proxy because the video pipeline can't actually deliver 48MP frames.
            func isPhotoFormat(_ format: AVCaptureDevice.Format) -> Bool {
                let maxFps = format.videoSupportedFrameRateRanges
                    .map(\.maxFrameRate)
                    .max() ?? 0
                return maxFps <= 30.0
            }
            let candidates = device.formats.filter { format in
                let s = score(format)
                if s == 0 { return false }
                if let ceiling = maxAreaCeiling, s > ceiling { return false }
                return true
            }
            // Compound ordering: (1) higher max-photo-dim wins; (2) among ties, the
            // pure-photo format wins over video-streaming formats.
            guard let best = candidates.max(by: { a, b in
                let scoreA = score(a)
                let scoreB = score(b)
                if scoreA != scoreB { return scoreA < scoreB }
                // Equal max-photo-dim: prefer the dedicated photo format.
                let photoA = isPhotoFormat(a)
                let photoB = isPhotoFormat(b)
                if photoA != photoB { return !photoA && photoB }
                return false
            }) else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Reconcile the photo output's auxiliary delivery flags with the destination
            // format BEFORE the format swap. The 48MP-capable format doesn't carry
            // depth / matte / Live Photo, and leaving those flags on across the swap
            // makes AVFoundation either silently reject the swap or downgrade the next
            // capture to a 144×192 preview proxy (the canonical "toggle does nothing /
            // export comes back tiny" symptom — see workspace lessons.md AVFoundation
            // section "48MP capture on iPhone 14 Pro+ / 15 Pro+").
            applyAuxiliaryPhotoOutputFlags(highRes: highRes)

            if best !== device.activeFormat {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeFormat = best
                } catch {
                    PRMLogger.session.warning(
                        "Failed to apply \(name, privacy: .public) format: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }

            // Must run inside the session config so the photo output validates the
            // new ceiling against the just-installed `activeFormat`. See the
            // `applyPhotoFormat` doc-comment for why this is required.
            refreshOutputMaxPhotoDimensions()

            // Diagnostic: surface the selected format's actual photo-dimension
            // capability so "Max Dimensions doesn't work" tickets have a single
            // log line to grep for. AVFoundation will silently reject the format
            // swap or downgrade captures if the selected format mismatches the
            // photo output's auxiliary flags — logging the picked dims here means
            // the failure mode is observable in Console.app without breakpoints.
            let pickedDims = best.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) })
            if let pickedDims {
                PRMLogger.session.notice(
                    "applyPhotoFormat(\(name, privacy: .public)) picked format with maxPhotoDimensions \(pickedDims.width, privacy: .public)×\(pickedDims.height, privacy: .public)"
                )
            }
        }

        /// Aligns the photo output's Live Photo / depth / portrait-matte / ZSL /
        /// deferred-delivery flags with the active format's capability. Called from
        /// inside `applyPhotoFormat` while the session is in a begin/commit window.
        ///
        /// - `highRes: true` — pin every auxiliary stream OFF. The 48MP photo format
        ///   doesn't carry depth, matte, or the Live Photo movie pipeline, and ZSL /
        ///   deferred proxy delivery both substitute 12MP captures. The original
        ///   `PRMCameraConfiguration` is preserved so the inverse path can restore
        ///   the user's intent.
        /// - `highRes: false` — re-apply each flag from the original
        ///   `PRMCameraConfiguration` (subject to the output's `is*Supported` gate).
        ///   We deliberately leave `isLivePhotoCaptureEnabled` alone here — runtime
        ///   Live Photo state is owned by `setLivePhotoCaptureEnabled(_:)` /
        ///   `applyModeChange` in the consuming app, not by configure-time defaults.
        private func applyAuxiliaryPhotoOutputFlags(highRes: Bool) {
            guard let output = photoOutput else { return }

            if highRes {
                if output.isLivePhotoCaptureEnabled {
                    output.isLivePhotoCaptureEnabled = false
                }
                if output.isDepthDataDeliverySupported, output.isDepthDataDeliveryEnabled {
                    output.isDepthDataDeliveryEnabled = false
                }
                if output.isPortraitEffectsMatteDeliverySupported, output.isPortraitEffectsMatteDeliveryEnabled {
                    output.isPortraitEffectsMatteDeliveryEnabled = false
                }
                if output.isAutoDeferredPhotoDeliverySupported, output.isAutoDeferredPhotoDeliveryEnabled {
                    output.isAutoDeferredPhotoDeliveryEnabled = false
                }
                if output.isZeroShutterLagSupported, output.isZeroShutterLagEnabled {
                    output.isZeroShutterLagEnabled = false
                }
            } else {
                guard let configuration else { return }
                if output.isDepthDataDeliverySupported {
                    let want = configuration.enableDepthDataDelivery
                    if output.isDepthDataDeliveryEnabled != want {
                        output.isDepthDataDeliveryEnabled = want
                    }
                }
                if output.isPortraitEffectsMatteDeliverySupported {
                    let want = configuration.enablePortraitEffectsMatteDelivery
                    if output.isPortraitEffectsMatteDeliveryEnabled != want {
                        output.isPortraitEffectsMatteDeliveryEnabled = want
                    }
                }
                if output.isAutoDeferredPhotoDeliverySupported {
                    let want = configuration.enableAutoDeferredPhotoDelivery
                    if output.isAutoDeferredPhotoDeliveryEnabled != want {
                        output.isAutoDeferredPhotoDeliveryEnabled = want
                    }
                }
                if output.isZeroShutterLagSupported {
                    let want = configuration.enableZeroShutterLag
                    if output.isZeroShutterLagEnabled != want {
                        output.isZeroShutterLagEnabled = want
                    }
                }
                // Don't touch isLivePhotoCaptureEnabled — owned by setLivePhotoCaptureEnabled
                // / consuming app's mode picker, not configure-time defaults.
            }
        }
    #endif

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
            guard let photoOutput else { return }
            // When enabling: if the current format / configuration doesn't support Live
            // Photo, try recovering by swapping the device's `activeFormat` to one that
            // does. The 48MP-capable photo format on iPhone 14 Pro+ / 15 Pro+ wide
            // explicitly drops the parallel movie pipeline Live Photo needs — without
            // this recovery, `setLivePhotoCaptureEnabled(true)` silently no-ops and the
            // next `captureLivePhoto` fails with "Live Photo is not enabled on the
            // photo output." Pulling the format flip in here means the photo output
            // doesn't need to know about the cross-feature exclusion.
            if enabled, !photoOutput.isLivePhotoCaptureSupported {
                applyLivePhotoCompatibleFormat()
            }
            guard photoOutput.isLivePhotoCaptureSupported else { return }
            guard photoOutput.isLivePhotoCaptureEnabled != enabled else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            photoOutput.isLivePhotoCaptureEnabled = enabled
        #endif
    }

    public func setMovieFileOutputAttached(_ attached: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if attached {
            if movieFileOutput == nil {
                try attachMovieFileOutput()
            }
            // Movie output forces Live Photo off; flip the flag to stay consistent.
            #if !os(macOS)
                if let photoOutput, photoOutput.isLivePhotoCaptureEnabled {
                    photoOutput.isLivePhotoCaptureEnabled = false
                }
            #endif
        } else {
            if let movieFileOutput {
                session.removeOutput(movieFileOutput)
                self.movieFileOutput = nil
            }
            #if !os(macOS)
                guard let photoOutput, let configuration, configuration.enableLivePhoto else { return }
                if photoOutput.isLivePhotoCaptureSupported, !photoOutput.isLivePhotoCaptureEnabled {
                    photoOutput.isLivePhotoCaptureEnabled = true
                }
            #endif
        }
    }
}
