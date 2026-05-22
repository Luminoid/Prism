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
    private var baselineActiveFormat: AVCaptureDevice.Format?

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
                try reconfigureForDevice(newDevice, configuration: configuration)
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
            configuration: PRMCameraConfiguration
        ) throws {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            tearDownAttachments()
            session.sessionPreset = configuration.sessionPreset

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
            if configuration.includesMovieFileOutput {
                try attachMovieFileOutput()
            }
            applyPreferredStabilization(configuration.preferredVideoStabilizationMode)
            let supported = photoOutput?.isLivePhotoCaptureSupported ?? false
            let enabled = photoOutput?.isLivePhotoCaptureEnabled ?? false
            PRMLogger.trace(
                .session,
                "reconfigureForDevice complete: device=\(device.localizedName), live(supported=\(supported), enabled=\(enabled))"
            )
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

    #if !os(macOS)
    #endif

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

        /// Re-applies the video-data-output's pixel-format override against the
        /// **current** active format. `AVCaptureVideoDataOutput.videoSettings` is
        /// honored per-active-format: each `device.activeFormat` swap invalidates
        /// the previous override and AVFoundation falls back to whatever the new
        /// format's `availableVideoCVPixelFormatTypes` declares first — typically
        /// the device's native `420f` YUV. On iPhone Pro models the depth-streaming
        /// format and the portrait-coupled 12MP format both deliver YUV by default
        /// and exclude BGRA from `availableVideoPixelFormatTypes` entirely (the
        /// list is `[420f, 420v, x420, x422, ...]` — no BGRA).
        ///
        /// Without this re-apply, frames after a format swap arrive as YUV; our
        /// preview path hardcodes `bgra8Unorm` and the BufferPoolAllocator
        /// requires `kCVPixelFormatType_32BGRA`, so the preview freezes. Re-writing
        /// `videoSettings` forces AVFoundation to validate against the new format
        /// — it honors the BGRA conversion when available, and we log a loud
        /// `.error` if BGRA isn't even in the list so the silent freeze becomes
        /// a single Console.app grep target.
        private func refreshVideoDataOutputPixelFormat() {
            guard let output = videoDataOutput else { return }
            let target = kCVPixelFormatType_32BGRA
            let available = output.availableVideoPixelFormatTypes
            guard available.contains(target) else {
                PRMLogger.session.error(
                    "videoDataOutput: BGRA not in availableVideoCVPixelFormatTypes after format swap (\(available, privacy: .public)) — preview may freeze"
                )
                return
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: target]
        }

        /// Aligns the photo output's Live Photo / depth / portrait-matte / ZSL /
        /// deferred-delivery flags with the active format's capability. Called from
        /// inside `applyPhotoFormat` and `restoreBaselineFormat` while the session
        /// is in a begin/commit window.
        ///
        /// - `highRes: true` — pin every auxiliary stream OFF. The 48MP photo format
        ///   doesn't carry depth, matte, or the Live Photo movie pipeline, and ZSL /
        ///   deferred proxy delivery both substitute 12MP captures. The original
        ///   `PRMCameraConfiguration` is preserved so the inverse path can restore.
        /// - `highRes: false` — re-apply each flag from the original
        ///   `PRMCameraConfiguration` (subject to the output's `is*Supported` gate,
        ///   which is active-format-dependent). Leaves `isLivePhotoCaptureEnabled`
        ///   alone — that runtime state is owned by `setLivePhotoCaptureEnabled(_:)`
        ///   / the consuming app's mode picker, not configure-time defaults.
        private func applyAuxiliaryPhotoOutputFlags(highRes: Bool) {
            guard let output = photoOutput else { return }
            let live = output.isLivePhotoCaptureEnabled
            let depth = output.isDepthDataDeliveryEnabled
            let matte = output.isPortraitEffectsMatteDeliveryEnabled
            let zsl = output.isZeroShutterLagEnabled
            let deferred = output.isAutoDeferredPhotoDeliveryEnabled
            PRMLogger.trace(
                .session,
                """
                applyAuxiliaryPhotoOutputFlags(highRes=\(highRes)) entry: \
                live=\(live), depth=\(depth), matte=\(matte), zsl=\(zsl), deferred=\(deferred)
                """
            )
            if highRes {
                if output.isLivePhotoCaptureEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isLivePhotoCaptureEnabled (was true)")
                    output.isLivePhotoCaptureEnabled = false
                }
                if output.isDepthDataDeliverySupported, output.isDepthDataDeliveryEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isDepthDataDeliveryEnabled (was true)")
                    output.isDepthDataDeliveryEnabled = false
                }
                if output.isPortraitEffectsMatteDeliverySupported, output.isPortraitEffectsMatteDeliveryEnabled {
                    PRMLogger.session.notice("aux-flags(highRes=true): disabling isPortraitEffectsMatteDeliveryEnabled (was true)")
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
            }
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
            PRMLogger.trace(.session, "applyHighResolutionPhotoFormat")
            // **Do NOT snapshot `baselineActiveFormat` here.** The configure-time
            // and `swapInput` snapshots are the authoritative "known-good" state.
            // A per-toggle snapshot would clobber that with whatever happens to be
            // active right now — and after a previous toggle-ON cycle the active
            // format is the 48MP one, which Live Photo / depth / matte all reject.
            // Re-toggling OFF would then "restore" to the 48MP format and break
            // every downstream feature that depends on a Live-Photo-compatible
            // active format. Trust the configure / swapInput snapshot — it's the
            // format AVFoundation actually picked at session-startup time when
            // every constraint (Live Photo, depth, BGRA delivery) was satisfied.
            applyPhotoFormat(name: "max-dimensions", maxAreaCeiling: nil, highRes: true)
        }

        /// Restores the active format to whatever was working at configure / pre-high-res
        /// time. **Does not compute a new format from scratch**: format introspection
        /// (`supportedDepthDataFormats`, frame-rate range, etc.) cannot predict whether
        /// `videoDataOutput.availableVideoPixelFormatTypes` will contain BGRA — that's
        /// computed by AVFoundation from the entire connection chain (device → input →
        /// connection → output), and on iPhone 15 Pro Max the 12MP `.photo`-preset
        /// portrait-coupled format excludes BGRA even though it looks identical to the
        /// regular 12MP format by every introspectable signal. So we trust the format
        /// AVFoundation picked at session-configure time (which we just rendered a
        /// preview with) and restore it verbatim.
        ///
        /// Also restores the auxiliary delivery flags (depth / portrait matte /
        /// deferred / ZSL) per `PRMCameraConfiguration` so the pre-toggle capture
        /// pipeline comes back intact.
        ///
        /// Falls back to the scored format pick (≤20MP, non-depth) when no baseline
        /// was captured — happens only if `applyHighResolutionPhotoFormat()` is the
        /// first format-swap call after configure (unusual; the snapshot path
        /// dominates real usage).
        func applyLivePhotoCompatibleFormat() {
            PRMLogger.trace(
                .session,
                "applyLivePhotoCompatibleFormat: baseline=\(baselineActiveFormat == nil ? "nil (will score)" : "captured")"
            )
            if let baseline = baselineActiveFormat {
                restoreBaselineFormat(baseline)
            } else {
                applyPhotoFormat(name: "Live-Photo-compatible", maxAreaCeiling: 20_000_000, highRes: false)
            }
        }

        /// Restore path: re-activate the previously-snapshotted format and re-apply
        /// the auxiliary flags + photo-output ceiling + videoDataOutput pixel-format
        /// override inside a single session begin/commit. No scoring, no probing —
        /// just put the device back where the user last had a working preview.
        private func restoreBaselineFormat(_ baseline: AVCaptureDevice.Format) {
            guard let device = videoDevice else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Reconcile aux flags FIRST so AVFoundation never sees a 48MP-format +
            // aux-flags-on transient on the way back. The current state coming in is
            // "48MP format + aux flags OFF" (set by applyHighResolutionPhotoFormat).
            // Targeting `highRes: false` re-enables depth/matte per PRMCameraConfiguration
            // if the destination format supports them (guarded by isDepthDataDeliverySupported).
            applyAuxiliaryPhotoOutputFlags(highRes: false)

            if baseline !== device.activeFormat {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeFormat = baseline
                } catch {
                    PRMLogger.session.warning(
                        "Failed to restore baseline activeFormat: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }

            refreshVideoDataOutputPixelFormat()
            refreshOutputMaxPhotoDimensions()

            let dims = baseline.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) })
            if let dims {
                PRMLogger.session.notice(
                    "applyLivePhotoCompatibleFormat: restored baseline format with maxPhotoDimensions \(dims.width, privacy: .public)×\(dims.height, privacy: .public)"
                )
            }
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
            /// Whether the format streams depth. On iPhone 14 Pro+ / 15 Pro+,
            /// depth-streaming formats **exclude BGRA** from
            /// `AVCaptureVideoDataOutput.availableVideoPixelFormatTypes` — the
            /// videoDataOutput delivers only YUV (`420f`, `420v`, `x420`, `x422`,
            /// plus 10-bit variants) on those formats. Our preview pipeline + filter
            /// pipeline both hardcode BGRA, so picking a depth-streaming format
            /// freezes the preview (every frame fails the BGRA gate). The
            /// `PRMCamera.enableDepthFormat()` path picks one deliberately when
            /// the consumer enters Portrait mode; the general Live-Photo-compatible
            /// fallback should NOT, because it's invoked on toggle-OFF from Max
            /// Dimensions and the user isn't expecting their preview to die.
            func isDepthStreamingFormat(_ format: AVCaptureDevice.Format) -> Bool {
                !format.supportedDepthDataFormats.isEmpty
            }
            let allCandidates = device.formats.filter { format in
                let s = score(format)
                if s == 0 { return false }
                if let ceiling = maxAreaCeiling, s > ceiling { return false }
                return true
            }
            // For the Live-Photo-compatible fallback path (no baseline snapshot
            // available): hard-prefer non-depth formats. Note that
            // `!supportedDepthDataFormats.isEmpty` is NOT a perfect signal — on
            // iPhone 15 Pro Max, the portrait-coupled 12MP format has an empty
            // depth-data list but still excludes BGRA from
            // `availableVideoPixelFormatTypes`. The proper handling is via
            // `applyLivePhotoCompatibleFormat`'s baseline-restore path; this
            // scoring is only the cold-start fallback.
            let candidates: [AVCaptureDevice.Format] = {
                if highRes { return allCandidates }
                let nonDepth = allCandidates.filter { !isDepthStreamingFormat($0) }
                return nonDepth.isEmpty ? allCandidates : nonDepth
            }()
            // Compound ordering: (1) higher max-photo-dim wins; (2) among ties, the
            // pure-photo format wins over video-streaming formats; (3) further ties
            // broken by non-depth-streaming preference.
            guard let best = candidates.max(by: { a, b in
                let scoreA = score(a)
                let scoreB = score(b)
                if scoreA != scoreB { return scoreA < scoreB }
                let photoA = isPhotoFormat(a)
                let photoB = isPhotoFormat(b)
                if photoA != photoB { return !photoA && photoB }
                let depthA = isDepthStreamingFormat(a)
                let depthB = isDepthStreamingFormat(b)
                if depthA != depthB { return depthA && !depthB }
                return false
            }) else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Reconcile the photo output's auxiliary delivery flags with the destination
            // format BEFORE the format swap. See `applyAuxiliaryPhotoOutputFlags` for
            // the rationale (48MP format incompatibilities + 144×192 proxy bug).
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

            // Re-apply videoDataOutput's BGRA pixel-format override and the photo
            // output's max-dimensions ceiling against the new active format. Both
            // must run inside the session config so AVFoundation re-validates them
            // against the just-installed format before the commit lands.
            refreshVideoDataOutputPixelFormat()
            refreshOutputMaxPhotoDimensions()

            let pickedDims = best.supportedMaxPhotoDimensions
                .filter { $0.width >= $0.height }
                .max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) })
            if let pickedDims {
                PRMLogger.session.notice(
                    "applyPhotoFormat(\(name, privacy: .public)) picked format with maxPhotoDimensions \(pickedDims.width, privacy: .public)×\(pickedDims.height, privacy: .public)"
                )
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
            PRMLogger.session.notice(
                "setLivePhotoCaptureEnabled: now \(enabled, privacy: .public)"
            )
        #endif
    }

    public func setMovieFileOutputAttached(_ attached: Bool) throws {
        PRMLogger.trace(.session, "setMovieFileOutputAttached(\(attached)): current=\(movieFileOutput != nil)")
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
