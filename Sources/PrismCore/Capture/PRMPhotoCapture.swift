@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Async-await wrapper for `AVCapturePhotoOutput`.
///
/// Replaces the old `PRMPhotoCaptureProcessor` four-callback API with a single
/// `try await capturePhoto(...)` returning a ``PRMPhoto`` struct.
///
/// One `PRMPhotoCapture` can be reused across multiple captures — each in-flight capture is
/// tracked by its `AVCaptureResolvedPhotoSettings.uniqueID`, so concurrent captures don't
/// step on each other.
///
/// Two initializers are exposed:
///
/// **Session-based (recommended)** — the wrapper resolves the *current*
/// `AVCapturePhotoOutput` from a `PRMCameraSession` at every capture entry point.
/// Survives the full-session-reconfigure paths that detach + re-attach the photo
/// output (Live-Photo recovery after a virtual-device swap; format swaps that
/// rebuild the secondary movie pipeline). Consuming apps don't have to
/// identity-check (`!==`) the session's current output before every capture.
///
/// ```swift
/// let capturer = PRMPhotoCapture(session: camera.session)
/// let photo = try await capturer.capturePhoto(
///     settings: PRMPhotoSettings().flashMode(.auto),
///     applying: SepiaFilter(intensity: 0.8),
///     context: renderContext
/// )
/// ```
///
/// **Output-based (legacy)** — bound to a single `AVCapturePhotoOutput` instance for
/// its lifetime. Captures will silently fail at the AVFoundation gate if Prism later
/// detaches that output (the `isLivePhotoCaptureSupported` / `maxPhotoDimensions` /
/// `connection(with: .video)` reads all return the dead values). Keep only if you
/// own the output yourself and it will never be replaced.
///
/// ```swift
/// let capturer = PRMPhotoCapture(output: photoOutput)
/// ```
public final class PRMPhotoCapture: NSObject, @unchecked Sendable {
    // MARK: - Resolver

    /// Resolution strategy for the underlying `AVCapturePhotoOutput`.
    private enum OutputResolver: @unchecked Sendable {
        /// Fixed output instance. Used by the legacy `init(output:)`.
        case fixed(AVCapturePhotoOutput)
        /// Dynamic lookup against a session. Used by `init(session:)` — re-resolves
        /// at every capture entry point so reconfigure-driven output re-attaches
        /// (Live-Photo recovery on virtual devices, format swaps that rebuild the
        /// secondary movie pipeline) don't strand the wrapper against a dead
        /// output instance whose `isLivePhotoCaptureSupported` reads false and
        /// `maxPhotoDimensions` reads (0, 0).
        case dynamic(@Sendable () async -> AVCapturePhotoOutput?)
    }

    // MARK: - Properties

    private let resolver: OutputResolver

    /// The output the wrapper was constructed against (legacy init) or — for the
    /// session-based init — the output snapshotted by the most recent capture
    /// resolution. The session-based init resolves the LIVE output at every
    /// capture entry point; reading this property between captures may return
    /// the previous capture's snapshot.
    ///
    /// Production callers should not need to read this directly — every capture
    /// entry point resolves a fresh reference internally. Exposed for
    /// back-compat with code that read `.output` once at construction time, and
    /// for downstream helpers like ``PRMNightModeCapture`` that share this
    /// wrapper.
    public var output: AVCapturePhotoOutput {
        if case let .fixed(out) = resolver {
            return out
        }
        if let cached = sessionCachedOutput {
            return cached
        }
        // Safe fallback: a fresh empty output. Should never be used in practice
        // because session-based callers go through a capture entry point that
        // calls the dynamic resolver. This branch only fires if a caller reads
        // `.output` before any capture has resolved one.
        return AVCapturePhotoOutput()
    }

    /// Cached output from the most recent capture entry point's resolution
    /// (session-based init only). Updated under `lock`.
    private var sessionCachedOutput: AVCapturePhotoOutput?

    /// Pending captures keyed by resolved settings ID.
    private var pendingCaptures: [Int64: PendingCapture] = [:]
    private let lock = NSLock()

    // MARK: - Init

    /// Legacy init. The wrapper is bound to `output` permanently — if Prism later
    /// detaches that output (e.g. on a Live-Photo-recovery reconfigure after a
    /// virtual-device swap), every capture will silently fail at the AVFoundation
    /// gate. Prefer ``init(session:)`` for any session that may reconfigure.
    public init(output: AVCapturePhotoOutput) {
        resolver = .fixed(output)
        super.init()
    }

    /// Session-based init. The wrapper resolves `session.photoOutput` at every
    /// capture entry point, so reconfigure-driven output replacements (Live-Photo
    /// recovery on virtual devices, format-swap-driven rebuilds of the secondary
    /// movie pipeline) are invisible to the caller.
    ///
    /// Capture entry points throw ``PRMSessionError/photoCaptureFailed`` if the
    /// session has no photo output attached at capture time.
    public init(session: PRMCameraSession) {
        // `nonisolated(unsafe)` is safe here — the closure only reads the actor-
        // isolated `photoOutput` snapshot through `await`, never mutates it.
        // The `@PRMCameraActor` isolation on the read ensures consistency with
        // any concurrent session reconfigure.
        resolver = .dynamic { [weak session] in
            guard let session else { return nil }
            return await session.photoOutput
        }
        super.init()
    }

    // MARK: - Resolution

    /// Returns the live `AVCapturePhotoOutput` per the configured resolver.
    /// Synchronous for `init(output:)`, actor-isolated read for `init(session:)`.
    ///
    /// For session-based wrappers, the resolved instance is cached under `lock`
    /// so subsequent reads of the public `output` property between captures
    /// observe the most recent snapshot. This also keeps identity-comparison
    /// (`===`) by downstream helpers (``PRMNightModeCapture``) stable across
    /// captures within a single session lifetime.
    ///
    /// Throws ``PRMSessionError/photoCaptureFailed`` when the session-based
    /// resolver returns nil — i.e. the consuming app hasn't attached a photo
    /// output to the session (`setPhotoOutputAttached(true)`) or the session
    /// has been torn down.
    private func resolveCurrentOutput() async throws -> AVCapturePhotoOutput {
        switch resolver {
        case let .fixed(out):
            return out
        case let .dynamic(resolve):
            guard let resolved = await resolve() else {
                throw PRMSessionError.photoCaptureFailed(
                    "AVCapturePhotoOutput is not attached to the session — call setPhotoOutputAttached(true) before capturing"
                )
            }
            cacheResolvedOutput(resolved)
            return resolved
        }
    }

    /// Non-async cache update under the wrapper's lock. Extracted into a
    /// `nonisolated` helper because `NSLock.lock` is not available in async
    /// contexts; the critical section is one pointer store, too small to
    /// justify an actor.
    private nonisolated func cacheResolvedOutput(_ output: AVCapturePhotoOutput) {
        lock.lock()
        defer { lock.unlock() }
        sessionCachedOutput = output
    }

    // MARK: - Capture

    /// Captures a photo, optionally applying a filter before encoding.
    ///
    /// - Parameters:
    ///   - settings: Builder for `AVCapturePhotoSettings`.
    ///   - filter: Optional filter; when non-nil, the captured data is re-encoded through it.
    ///   - context: Render context for filter encode. Required if `filter` is non-nil.
    ///   - willCapture: Called the moment the shutter fires (for animation).
    /// - Returns: A ``PRMPhoto`` with encoded data + metadata.
    public func capturePhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        applying filter: (any PRMFilter)? = nil,
        context: PRMRenderContext? = nil,
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMPhoto {
        try await capturePhoto(
            settings: settings,
            filterRecipe: filter.map { .single($0, context: context) } ?? .none,
            willCapture: willCapture
        )
    }

    /// Captures a photo and re-encodes it through every entry in `chainEntries`, with
    /// per-entry intensity blending (the same blend math used by ``PRMFilterChain``
    /// during live preview). Use this when you want the still capture to match what the
    /// user sees in a chain-driven preview.
    ///
    /// Pass a snapshot of the chain's `entries` — the array is iterated once at encode
    /// time, so mutating the chain after this call returns has no effect on the result.
    ///
    /// - Parameters:
    ///   - settings: Builder for `AVCapturePhotoSettings`.
    ///   - chainEntries: Filter chain entries to apply in order. Empty array re-encodes
    ///     the original frame unchanged (still pays the round-trip through `PRMImage` —
    ///     prefer the no-filter overload if no filtering is intended).
    ///   - context: Render context for the filter encode. Required.
    ///   - willCapture: Called the moment the shutter fires (for animation).
    /// - Returns: A ``PRMPhoto`` with encoded data + metadata.
    public func capturePhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        applyingChain chainEntries: [PRMFilterChain.Entry],
        context: PRMRenderContext,
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMPhoto {
        try await capturePhoto(
            settings: settings,
            filterRecipe: .chain(chainEntries, context: context),
            willCapture: willCapture
        )
    }

    /// Internal common path shared by both `applying:` and `applyingChain:` overloads.
    /// Both forms produce the same delegate / continuation plumbing — only the filter
    /// recipe differs at encode time.
    private func capturePhoto(
        settings: PRMPhotoSettings,
        filterRecipe: FilterRecipe,
        willCapture: (@Sendable () -> Void)?
    ) async throws -> PRMPhoto {
        // Resolve the live photo output. For session-based wrappers this picks
        // up the CURRENT `session.photoOutput`, which is critical because
        // Prism's full-session-reconfigure paths (Live-Photo recovery after a
        // virtual-device swap, format-swap-driven secondary movie pipeline
        // rebuilds) detach and re-attach the underlying `AVCapturePhotoOutput`.
        // A stale capture against the detached instance would read
        // `isLivePhotoCaptureSupported = false`, `maxPhotoDimensions = (0, 0)`,
        // and `connection(with: .video) = nil`, then fail at the AVFoundation
        // gate with no obvious cause. For legacy `init(output:)` wrappers the
        // resolver returns the fixed reference.
        let liveOutput = try await resolveCurrentOutput()
        let maxDim = liveOutput.maxPhotoDimensions
        let live = liveOutput.isLivePhotoCaptureEnabled
        let depth = liveOutput.isDepthDataDeliveryEnabled
        PRMLogger.trace(
            .capture,
            "capturePhoto entry: maxDim=\(maxDim.width)×\(maxDim.height), live=\(live), depth=\(depth)"
        )
        // Route through a single-frame photo bracket whenever the device is in
        // `.custom` exposure mode. `AVCapturePhotoBracketSettings` natively
        // disables Smart HDR, Deep Fusion, virtual-device fusion, dual-camera
        // fusion, still-image stabilization, and red-eye reduction — all the
        // computational paths that override the user's manual ISO / shutter on
        // a regular `AVCapturePhotoSettings` capture (see AVCapturePhotoOutput.h
        // doc comments around `autoVirtualDeviceFusionEnabled` lines 1390-1412
        // in the iOS 26 SDK: each is "Default is YES … *unless you are
        // capturing a bracket using AVCapturePhotoBracketSettings*"). This is
        // the canonical Apple-recommended path for true manual capture, used
        // by AVCamManual sample since iOS 8.
        let avSettings: AVCapturePhotoSettings
        // Capture the user-intended manual exposure values BEFORE the bracket
        // fires. Prefer `settings.manualExposureOverride` (populated by the
        // caller from PRMCamera's intent snapshot — what the slider actually
        // shows) over reading `device.iso` / `device.exposureDuration` directly
        // (which can lag the user's commit by up to ~3s per dev-forum 751112,
        // and the bracket's EXIF still gets written with auto-AE values per
        // dev-forum 120427). Override wins so the saved EXIF matches the UI.
        let manualISO: Float?
        let manualDuration: CMTime?
        if let bracket = manualExposureBracketSettings(from: settings, output: liveOutput) {
            avSettings = bracket
            if let override = settings.manualExposureOverride {
                manualISO = override.iso
                manualDuration = override.duration
            } else if let device = activeDevice(of: liveOutput) {
                manualISO = device.iso
                manualDuration = device.exposureDuration
            } else {
                manualISO = nil
                manualDuration = nil
            }
        } else {
            manualISO = nil
            manualDuration = nil
            // `makeAVSettings(for:)` drops unsupported codecs (e.g. HEVC on the
            // simulator or on older devices that report `[.jpeg]` only) so
            // AVFoundation doesn't throw `NSInvalidArgumentException` at
            // `capturePhotoWithSettings:`. The filter-pass re-encode below
            // honors the *requested* codec independently, so a chain capture
            // can still emit HEIF even if the underlying photo output couldn't.
            let regular = settings.makeAVSettings(for: liveOutput)
            clampFlashMode(on: regular, output: liveOutput)
            applyManualExposureOverrides(on: regular, output: liveOutput)
            avSettings = regular
        }
        let pending = PendingCapture(
            kind: .single,
            filterRecipe: filterRecipe,
            filterCodec: settings.codec,
            manualISO: manualISO,
            manualExposureDuration: manualDuration,
            willCapture: willCapture
        )

        // Validate the video connection exists AND is active BEFORE calling
        // `capturePhoto`. AVFoundation's underlying ObjC implementation throws an
        // **uncaught** `NSInvalidArgumentException` ("*** -[AVCapturePhotoOutput
        // capturePhotoWithSettings:delegate:] No active and enabled video
        // connection") when no active connection exists — same crash class as
        // `AVCaptureMovieFileOutput.startRecording`. Swift's `try / catch` cannot
        // intercept an ObjC exception thrown from an async continuation context;
        // the process terminates. Surfacing a typed `PRMSessionError` here lets
        // the consuming app present a toast and reconfigure instead of crashing.
        //
        // The connection can go absent in several scenarios:
        // - the session is currently between begin/commit of a reconfigure that
        //   detached + is about to re-attach the photo output,
        // - the device just switched (Triple → Wide on slo-mo) and the photo
        //   output's video connection didn't survive the swap,
        // - the session's `sessionPreset` was left at `.inputPriority` after a
        //   slo-mo workflow without restoring the original preset — which leaves
        //   the photo output without an active connection on the Triple camera,
        // - the user just toggled Live Photo enabled/disabled, which on virtual
        //   devices (Triple / Dual / DualWide) clears `output.maxPhotoDimensions`
        //   to (0, 0) AND transiently invalidates the video connection while the
        //   secondary movie pipeline rebuilds. AVFoundation finishes this rebuild
        //   asynchronously after `commitConfiguration` returns — typically within
        //   100-300 ms (vision-camera PR #3637 polls similarly). A first capture
        //   immediately after a Wide → Triple swap + Live Photo toggle would see
        //   the still-invalidated connection without a poll window.
        //
        // The poll is bounded (`waitForVideoConnection(timeout:)` — 3 s) and
        // uses small steps so the user-perceived shutter lag is minimal when the
        // pipeline is immediately ready (typical case). 3 s covers the worst-case
        // Triple-Camera-after-SLO-MO rebuild observed empirically. If the poll
        // exhausts, we surface the typed error instead of crashing.
        try await waitForVideoConnection(timeout: 3.0, output: liveOutput)
        // After the connection returns, `maxPhotoDimensions` may still read
        // (0, 0) — the same Live-Photo-toggle invalidation that broke the
        // connection also resets the per-format ceiling. Re-derive from the
        // active device's current format. No session begin/commit needed: by
        // the time we get here the async re-validation is done and a bare
        // assignment lands. Skip when the ceiling is already populated (the
        // common case — only the post-toggle first-capture path goes through
        // this branch).
        healMaxPhotoDimensionsIfNeeded(output: liveOutput)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.singleContinuation = continuation
                lock.lock()
                pendingCaptures[avSettings.uniqueID] = pending
                lock.unlock()
                liveOutput.capturePhoto(with: avSettings, delegate: self)
            }
        } onCancel: { [weak self] in
            self?.markCancelled(avSettings.uniqueID)
        }
    }

    /// If the active device is in manual exposure (`.custom`), build a
    /// single-frame `AVCapturePhotoBracketSettings` that bakes in the device's
    /// current `iso` and `exposureDuration`. Returns nil for auto modes so the
    /// caller uses the regular `AVCapturePhotoSettings` path (with all the
    /// modern Smart HDR / Deep Fusion enhancements intact for auto shots).
    ///
    /// `AVCapturePhotoBracketSettings` doesn't support flashMode or
    /// livePhotoMovieFileURL, so this is only viable when the user is in
    /// manual exposure (where flash + Live Photo are conceptually incompatible
    /// anyway — flash forces auto-exposure, and Live Photo requires the AE
    /// system to keep tracking for the post-shutter frames).
    private func manualExposureBracketSettings(
        from settings: PRMPhotoSettings,
        output: AVCapturePhotoOutput
    ) -> AVCapturePhotoBracketSettings? {
        // Trust the caller's `manualExposureOverride` as the primary signal —
        // it reflects the user's slider intent (truth) rather than the device's
        // lagging `exposureMode` read (can lag the commit by ~3s per dev-forum
        // 751112, AND on iPhone 15 Pro+ the multi-camera virtual-device path
        // can return raw=-1 / iso=0 / dur=0 garbage when polled mid-XPC stall —
        // observed in user logs with FigCaptureSourceRemote err=-17281
        // accompanying). Falling back to `device.exposureMode == .custom` as
        // a secondary gate covers callers that don't pass the override yet
        // (legacy or non-Studio consumers).
        let hasOverride = settings.manualExposureOverride != nil
        let deviceInCustom = activeDevice(of: output)?.exposureMode == .custom
        guard hasOverride || deviceInCustom else { return nil }

        // Bracket settings need a processed-format dictionary if you want a
        // specific codec (HEIC/HEVC). Match the regular path's codec selection
        // including the "drop unsupported codec" fallback to JPEG.
        let processedFormat: [String: Any]? = if let codec = settings.codec,
                                                 output.availablePhotoCodecTypes.contains(codec) {
            [AVVideoCodecKey: codec]
        } else {
            nil
        }

        // Prefer explicit override values (user-intent) over the
        // `currentExposureDuration` / `currentISO` sentinels. The sentinels
        // read whatever the device has at bracket-resolve time — which on the
        // broken multi-camera path is the device's stale auto values, not the
        // user's slider intent. Baking explicit values into the bracket
        // closes that gap.
        let bracketed: AVCaptureBracketedStillImageSettings = if let override = settings.manualExposureOverride {
            AVCaptureManualExposureBracketedStillImageSettings
                .manualExposureSettings(
                    exposureDuration: override.duration,
                    iso: override.iso
                )
        } else {
            AVCaptureManualExposureBracketedStillImageSettings
                .manualExposureSettings(
                    exposureDuration: AVCaptureDevice.currentExposureDuration,
                    iso: AVCaptureDevice.currentISO
                )
        }
        let bracket = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: processedFormat,
            bracketedSettings: [bracketed]
        )
        if let maxDimensions = settings.maxDimensions {
            bracket.maxPhotoDimensions = maxDimensions
        }
        return bracket
    }

    /// When the active capture device is in manual exposure (`.custom`), `.locked`
    /// exposure, or locked WB, downgrade `photoQualityPrioritization` to `.speed`
    /// and turn off deferred-photo-proxy delivery for this single capture. AVFoundation's
    /// `.balanced` and `.quality` pipelines run multi-frame fusion (Deep Fusion,
    /// Smart HDR) that **fuse several differently-exposed images**: the captured
    /// photo's EXIF shows fused/averaged ISO and shutter, not the values the user
    /// set via `setExposureModeCustom`. `.speed` is documented as WYSIWYG —
    /// "lightly processed only with some noise reduction applied" per WWDC21
    /// session 10247 — and is the only mode that honors a manual exposure exactly.
    ///
    /// Auto-deferred photo delivery returns a low-res proxy that the Photos
    /// framework "upgrades" with the fusion path's full-resolution output. The
    /// upgrade path runs after the device may have left the manual mode (e.g.
    /// the user lifted their finger and the AE system re-asserted), so the
    /// upgraded photo can also drift from the manual values. Forcing the
    /// per-capture `isAutoStillImageStabilizationEnabled = false` is the
    /// matching pre-iOS 13 knob; on iOS 13+ the deferred / fusion paths are the
    /// concrete culprits.
    ///
    /// Same logic for locked WB: the fusion path can blend frames captured
    /// with re-metered WB, washing out the locked Kelvin. Downgrade to `.speed`
    /// when WB is `.locked` so the rendered frame matches the live preview.
    ///
    /// Caller-supplied overrides win: if `PRMPhotoSettings.qualityPrioritization`
    /// was explicitly set to `.balanced` or `.quality` AND the device is in a
    /// manual mode, we still downgrade — the manual mode is a strong intent and
    /// the user would not understand "I set ISO 800 and the photo shows ISO 200".
    /// If the device is in continuous-auto, we leave the caller's choice alone.
    private func applyManualExposureOverrides(
        on settings: AVCapturePhotoSettings,
        output: AVCapturePhotoOutput
    ) {
        guard let device = activeDevice(of: output) else { return }
        let exposureIsManual = device.exposureMode == .custom || device.exposureMode == .locked
        let whiteBalanceIsLocked = device.whiteBalanceMode == .locked
        guard exposureIsManual || whiteBalanceIsLocked else { return }
        settings.photoQualityPrioritization = .speed
        #if !os(macOS)
            if output.isAutoDeferredPhotoDeliveryEnabled {
                // Per-capture opt-out via the resolved-settings inspection:
                // AVCapturePhotoSettings doesn't expose a deferred toggle directly,
                // but `.speed` quality (above) is documented to bypass the deferred
                // proxy path. The output-level flag stays on for subsequent
                // continuous-auto captures, which still benefit from the proxy.
                // (Reading the flag here just confirms the session config so the
                // log message below is accurate; setting it false would mutate
                // the shared output for ALL future captures, which is wrong.)
                PRMLogger.capture.debug(
                    "Manual exposure / locked WB at capture time — downgrading photoQualityPrioritization to .speed (was .quality / .balanced)"
                )
            }
        #endif
    }

    /// Polls `output.connection(with: .video)` AND `output.captureReadiness` for up
    /// to `timeout` seconds, returning when the connection is present, active and
    /// enabled AND the photo output reports `.ready`. Throws
    /// ``PRMSessionError/photoCaptureFailed`` if either condition is unsatisfied at
    /// timeout.
    ///
    /// Necessary because AVFoundation's `commitConfiguration` returns *before* the
    /// async re-validation of `AVCapturePhotoOutput` finishes. On virtual devices
    /// (Triple / Dual / DualWide), a recent Live-Photo toggle or `swapInput`-driven
    /// reconfigure can leave the video connection in a transient `nil` /
    /// `isActive=false` state for **2-3 seconds** after the commit — well past any
    /// reasonable polling window. Vision-camera PR #3637's 500 ms poll is too short
    /// for the Triple-Camera-after-SLO-MO path.
    ///
    /// **`AVCapturePhotoOutput.captureReadiness`** (iOS 17+, per WWDC23 session
    /// 10105) is Apple's documented signal for this exact case: `.sessionNotRunning`
    /// covers the post-`commitConfiguration` rebuild window, transitioning to
    /// `.ready` exactly when the pipeline (including connections) finishes
    /// re-validating. Polling this property is the simplest correct path —
    /// `AVCapturePhotoOutputReadinessCoordinator` provides a delegate-driven
    /// equivalent but with the same underlying signal. The poll's job is to
    /// observe the property; the property is the source of truth.
    ///
    /// 50 ms poll cadence balances shutter responsiveness (no perceptible lag
    /// when the connection is immediately available — the common case) against
    /// the post-reconfigure recovery window. 3 s timeout is generous enough for
    /// the Triple-Camera-after-SLO-MO rebuild observed empirically; if it
    /// exhausts, the session is in a non-recoverable state and the consuming
    /// app should reconfigure.
    private func waitForVideoConnection(
        timeout: TimeInterval,
        output: AVCapturePhotoOutput
    ) async throws {
        let pollStep: UInt64 = 50_000_000 // 50 ms in nanoseconds
        let deadline = Date().addingTimeInterval(timeout)
        var lastFailureReason: String?
        while Date() < deadline {
            let connection = output.connection(with: .video)
            let connectionReady = connection?.isEnabled == true && connection?.isActive == true
            let readiness = output.captureReadiness
            if connectionReady, readiness == .ready {
                return
            }
            // Build a precise failure reason so the timeout message points at the
            // actual stuck signal, not just "something is unready."
            switch (connection, readiness) {
            case (nil, _):
                lastFailureReason = "no video connection, readiness=\(readiness.rawValue)"
            case (_?, .ready) where !connectionReady:
                lastFailureReason = "connection inactive/disabled, readiness=.ready"
            case (_?, .sessionNotRunning):
                lastFailureReason = "readiness=.sessionNotRunning (pipeline still rebuilding)"
            case (_?, .notReadyMomentarily):
                lastFailureReason = "readiness=.notReadyMomentarily"
            case (_?, .notReadyWaitingForCapture):
                lastFailureReason = "readiness=.notReadyWaitingForCapture (prior capture in flight)"
            case (_?, .notReadyWaitingForProcessing):
                lastFailureReason = "readiness=.notReadyWaitingForProcessing"
            default:
                lastFailureReason = "connection+readiness mismatch"
            }
            try? await Task.sleep(nanoseconds: pollStep)
        }
        throw PRMSessionError.photoCaptureFailed(
            "AVCapturePhotoOutput not ready after \(Int(timeout * 1000)) ms poll (\(lastFailureReason ?? "unknown")) — session may need to be reconfigured"
        )
    }

    /// Re-asserts `output.maxPhotoDimensions` against the active device's current
    /// format when the cached ceiling has been clobbered to `(0, 0)`.
    ///
    /// Same root cause as ``waitForVideoConnection(timeout:)``: a recent Live-Photo
    /// toggle resets the photo output's per-format ceilings. `PRMCameraSession`'s
    /// session-side re-apply runs inside the toggle's `beginConfiguration` /
    /// `commitConfiguration` block, but on virtual devices the assignment is
    /// sometimes silently rejected — AVFoundation hasn't finished re-validating the
    /// pipeline yet, so the bare commit-time write of `maxPhotoDimensions` doesn't
    /// stick. By the time we poll the connection back in
    /// `waitForVideoConnection`, the async re-validation is done and a plain
    /// assignment (no session begin/commit) lands.
    ///
    /// No-op when `maxPhotoDimensions` is already non-zero (the common case;
    /// only the first capture immediately after a virtual-device toggle hits the
    /// `(0, 0)` path).
    private func healMaxPhotoDimensionsIfNeeded(output: AVCapturePhotoOutput) {
        let current = output.maxPhotoDimensions
        guard current.width == 0 || current.height == 0 else { return }
        guard let device = activeDevice(of: output) else { return }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
            .filter { $0.width >= $0.height }
        guard let largest = supported.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        output.maxPhotoDimensions = largest
        PRMLogger.capture.notice(
            "healMaxPhotoDimensions: re-applied \(largest.width, privacy: .public)×\(largest.height, privacy: .public) (was 0×0 after async pipeline re-validation)"
        )
    }

    /// The video device currently feeding the given photo output. Walks
    /// `output.connections` (the single video connection) to its first input port
    /// and casts to `AVCaptureDeviceInput`. Returns `nil` if the output isn't
    /// attached to a session — captures would already fail in that state, so
    /// callers can safely no-op when this returns nil.
    private func activeDevice(of output: AVCapturePhotoOutput) -> AVCaptureDevice? {
        for connection in output.connections {
            for port in connection.inputPorts {
                if let deviceInput = port.input as? AVCaptureDeviceInput {
                    return deviceInput.device
                }
            }
        }
        return nil
    }

    /// Force `AVCapturePhotoSettings.flashMode` into a value the current photo output
    /// actually supports. `AVCapturePhotoOutput.supportedFlashModes` changes per device
    /// (front camera has no flash hardware) and per session preset; setting `flashMode`
    /// to a mode not in that list silently drops to `.off` with no warning, which makes
    /// "Auto flash isn't firing" look like a Prism bug when it's really an unsupported
    /// request. When `.auto` is unsupported we fall through to `.on` (closest behavioral
    /// match — "fire flash when shutter opens"), then `.off` as a last resort.
    private func clampFlashMode(
        on settings: AVCapturePhotoSettings,
        output: AVCapturePhotoOutput
    ) {
        let supported = output.supportedFlashModes
        guard !supported.contains(settings.flashMode) else { return }
        let fallback: AVCaptureDevice.FlashMode = if supported.contains(.auto) {
            .auto
        } else if supported.contains(.on) {
            .on
        } else {
            .off
        }
        settings.flashMode = fallback
    }

    /// Captures a Live Photo: still image + paired movie. Both must finish before this
    /// returns. Throws if the photo output was not configured with
    /// ``PRMCameraConfiguration/enableLivePhoto`` set to `true`.
    ///
    /// The movie sidecar is written to a unique URL under `<tmp>/Prism/`. The caller is
    /// responsible for moving or deleting the file (consumers typically save both pieces
    /// to `PHPhotoLibrary` as a paired resource).
    public func captureLivePhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMLivePhoto {
        #if os(macOS)
            throw PRMSessionError.photoCaptureFailed("Live Photo is unavailable on macOS")
        #else
            // See `capturePhoto` for the full rationale on resolving the LIVE
            // output before any property read. Live Photo is especially
            // sensitive to stale references because the Live-Photo-recovery
            // reconfigure path in `PRMCameraSession.swapInput` is the dominant
            // source of detached photo-output instances.
            let liveOutput = try await resolveCurrentOutput()
            guard liveOutput.isLivePhotoCaptureSupported, liveOutput.isLivePhotoCaptureEnabled else {
                let supported = liveOutput.isLivePhotoCaptureSupported
                let enabled = liveOutput.isLivePhotoCaptureEnabled
                PRMLogger.capture.error(
                    "captureLivePhoto: refused — isLivePhotoCaptureSupported=\(supported, privacy: .public), isLivePhotoCaptureEnabled=\(enabled, privacy: .public)"
                )
                throw PRMSessionError.photoCaptureFailed(
                    "Live Photo is not enabled on the photo output (supported=\(supported), enabled=\(enabled)). Call camera.setLivePhotoCaptureEnabled(true)."
                )
            }
            PRMLogger.trace(
                .capture,
                "captureLivePhoto entry: supported=\(liveOutput.isLivePhotoCaptureSupported), enabled=\(liveOutput.isLivePhotoCaptureEnabled)"
            )
            let liveSettings = settings.livePhoto(true).makeAVSettings(for: liveOutput)
            clampFlashMode(on: liveSettings, output: liveOutput)
            applyManualExposureOverrides(on: liveSettings, output: liveOutput)
            let movieURL = PRMTempFile.url(withExtension: "mov")
            liveSettings.livePhotoMovieFileURL = movieURL

            let pending = PendingCapture(
                kind: .live(movieURL: movieURL),
                filterRecipe: .none,
                willCapture: willCapture
            )

            // Same guard as the single-capture path. Poll for the photo output
            // to reach `.ready` if it's transiently rebuilding after a recent
            // session begin/commit (Live Photo toggle, swapInput rebuild). See
            // the `capturePhoto` companion site for the full rationale.
            do {
                try await waitForVideoConnection(timeout: 3.0, output: liveOutput)
            } catch {
                PRMTempFile.remove(movieURL)
                throw error
            }
            healMaxPhotoDimensionsIfNeeded(output: liveOutput)

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.liveContinuation = continuation
                    lock.lock()
                    pendingCaptures[liveSettings.uniqueID] = pending
                    lock.unlock()
                    liveOutput.capturePhoto(with: liveSettings, delegate: self)
                }
            } onCancel: { [weak self] in
                self?.markCancelled(liveSettings.uniqueID)
            }
        #endif
    }

    /// Captures a burst of `count` photos in rapid succession. Returns when every photo
    /// finishes. Use sparingly — large bursts hold many AVCapturePhotos in memory.
    ///
    /// Captures are issued sequentially: `AVCapturePhotoOutput` does not support
    /// concurrent `capturePhoto(with:delegate:)` calls and throws `NSInvalidArgumentException`
    /// ("Settings may not be re-used") when two captures overlap. Enable
    /// `PRMCameraConfiguration.enableResponsiveCapture` to minimize per-shot latency.
    public func captureBurst(
        count: Int,
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> [PRMPhoto] {
        PRMLogger.trace(.capture, "captureBurst entry: count=\(count)")
        guard count > 0 else { return [] }
        var results: [PRMPhoto] = []
        results.reserveCapacity(count)
        for index in 0 ..< count {
            let photo = try await capturePhoto(
                settings: settings,
                willCapture: index == 0 ? willCapture : nil
            )
            results.append(photo)
        }
        return results
    }

    // MARK: - Pending tracker

    enum PendingKind {
        case single
        case live(movieURL: URL)
    }

    /// Encoder-time recipe for the optional filter pass: nothing, one filter, or a chain
    /// snapshot. Both shapes share the same render context requirement, so threading the
    /// context through the case payloads keeps the encode-time call site exhaustive.
    enum FilterRecipe {
        case none
        case single(any PRMFilter, context: PRMRenderContext?)
        case chain([PRMFilterChain.Entry], context: PRMRenderContext)
    }

    final class PendingCapture {
        let kind: PendingKind
        let filterRecipe: FilterRecipe
        /// Encoder choice for the filter pass. `nil` means "no filter pass" — the original
        /// AVFoundation-encoded payload is used verbatim. Otherwise the encode honors the
        /// codec the caller requested on `PRMPhotoSettings` so HEIC selections actually
        /// produce HEIC output (the filter pass re-encodes from scratch via CoreImage —
        /// AVFoundation's codec choice only applies to the *original* photo data).
        let filterCodec: AVVideoCodecType?
        let willCapture: (@Sendable () -> Void)?
        /// ISO and exposure duration sampled from the active device immediately
        /// before `output.capturePhoto(with:delegate:)` fired, when the device
        /// was in `.custom` exposure mode. Used to patch the resulting
        /// AVCapturePhoto's EXIF in `finishCapture` — AVFoundation's bracket
        /// capture path on iPhone 14 Pro+ has a long-standing bug where the
        /// auto-AE values are written into the photo's EXIF even when the
        /// frame was captured at manual exposure. Apple dev-forum 120427:
        /// "the exposure ISO and duration in the AVCapturePhoto's metadata
        /// will often be completely different from the values provided to
        /// setExposureModeCustom." Reading the device state at capture time
        /// is the canonical fix (replacing the metadata via
        /// `fileDataRepresentation(withReplacementMetadata:...)`).
        let manualISO: Float?
        let manualExposureDuration: CMTime?
        var singleContinuation: CheckedContinuation<PRMPhoto, Error>?
        var liveContinuation: CheckedContinuation<PRMLivePhoto, Error>?
        var cancelled: Bool = false
        var capturedPhoto: PRMPhoto?
        var liveMovieReady: Bool = false
        var liveMovieError: Error?

        init(
            kind: PendingKind,
            filterRecipe: FilterRecipe,
            filterCodec: AVVideoCodecType? = nil,
            manualISO: Float? = nil,
            manualExposureDuration: CMTime? = nil,
            willCapture: (@Sendable () -> Void)?
        ) {
            self.kind = kind
            self.filterRecipe = filterRecipe
            self.filterCodec = filterCodec
            self.manualISO = manualISO
            self.manualExposureDuration = manualExposureDuration
            self.willCapture = willCapture
        }
    }

    fileprivate func peek(_ id: Int64) -> PendingCapture? {
        lock.lock()
        let pending = pendingCaptures[id]
        lock.unlock()
        return pending
    }

    private func markCancelled(_ id: Int64) {
        lock.lock()
        if let pending = pendingCaptures[id] {
            pending.cancelled = true
        }
        lock.unlock()
    }

    fileprivate func renderPhoto(
        originalData: Data,
        photo: AVCapturePhoto,
        pending: PendingCapture
    ) -> PRMPhoto {
        let metadata = photo.metadata
        let finalData: Data

        switch pending.filterRecipe {
        case .none:
            finalData = originalData

        case let .single(filter, context):
            guard let context, let sourceImage = CIImage(data: originalData) else {
                finalData = originalData
                break
            }
            let filtered = filter.render(sourceImage)
            let preservedProperties = sourceImage.properties.merging(metadata) { _, new in new }
            finalData = Self.encodeFilteredImage(
                filtered,
                sourceExtent: sourceImage.extent,
                preservedProperties: preservedProperties,
                codec: pending.filterCodec,
                context: context
            ) ?? originalData

        case let .chain(entries, context):
            guard let sourceImage = CIImage(data: originalData) else {
                finalData = originalData
                break
            }
            // Reuse the chain's own static helper so the still-capture output matches
            // the live preview pixel-for-pixel (same intensity-blend math, same order).
            let blended = PRMFilterChain.apply(entries, to: sourceImage)
            let preservedProperties = sourceImage.properties.merging(metadata) { _, new in new }
            finalData = Self.encodeFilteredImage(
                blended,
                sourceExtent: sourceImage.extent,
                preservedProperties: preservedProperties,
                codec: pending.filterCodec,
                context: context
            ) ?? originalData
        }
        return PRMPhoto(data: finalData, underlyingPhoto: photo, metadata: metadata)
    }

    /// Route the filtered CIImage to the codec the caller asked for on `PRMPhotoSettings`.
    /// `.hevc` (or anything HEIC-family) maps to ``PRMImage/heifDataPreservingMetadata``;
    /// everything else falls back to JPEG so callers that don't care about codec still get
    /// usable output. Falls back to JPEG if HEIF encode returns `nil` (older sims with no
    /// HEVC encoder).
    ///
    /// `sourceExtent` is the pre-filter source CIImage's extent — required because
    /// distortion filters (Bump, Twirl, Vortex, Edges) produce infinite extents that
    /// `heifRepresentation` silently rejects (returns nil → falls back to JPEG with no
    /// caller signal). Cropping to the source frame inside the encoder restores the
    /// expected output.
    private static func encodeFilteredImage(
        _ image: CIImage,
        sourceExtent: CGRect,
        preservedProperties: [String: Any],
        codec: AVVideoCodecType?,
        context: PRMRenderContext
    ) -> Data? {
        if codec == .hevc || codec == .hevcWithAlpha {
            if let heif = PRMImage.heifDataPreservingMetadata(
                from: image,
                sourceExtent: sourceExtent,
                originalProperties: preservedProperties,
                context: context
            ) {
                PRMLogger.capture.debug("Encoded filter chain → HEIC (\(heif.count, privacy: .public) bytes)")
                return heif
            }
            PRMLogger.capture.notice("HEIF encode returned nil — falling back to JPEG")
        }
        return PRMImage.jpegDataPreservingMetadata(
            from: image,
            sourceExtent: sourceExtent,
            originalProperties: preservedProperties,
            context: context
        )
    }

    /// Override the EXIF `ExposureTime`, `ISOSpeedRatings`, and
    /// `ShutterSpeedValue` fields in the captured photo's metadata with the
    /// manual values the device was actually set to at capture time. Uses
    /// `AVCapturePhoto.fileDataRepresentation(with:)` with a customizer
    /// callback — the only API that lets us write back into the photo's
    /// container without losing the AVFoundation-written maker-notes / depth /
    /// matte. The pre-iOS-12 `withReplacementMetadata:` overload is deprecated
    /// in favor of this protocol-based variant.
    ///
    /// Returns `nil` (caller falls back to the unpatched data) if AVFoundation
    /// declines the replacement.
    private static func fileDataReplacingExposure(
        photo: AVCapturePhoto,
        iso: Float,
        exposureDuration: CMTime
    ) -> Data? {
        let customizer = ExposurePatchCustomizer(iso: iso, exposureDuration: exposureDuration)
        return photo.fileDataRepresentation(with: customizer)
    }
}

/// `AVCapturePhotoFileDataRepresentationCustomizer` that patches EXIF
/// `ExposureTime`, `ISOSpeedRatings`, and `ShutterSpeedValue` with manual
/// values sampled from the device at bracket-fire time. AVFoundation calls
/// `replacementMetadataForPhoto:` synchronously when flattening the photo,
/// so the customizer's lifetime only needs to span the one
/// `fileDataRepresentation(with:)` call.
private final class ExposurePatchCustomizer: NSObject,
    AVCapturePhotoFileDataRepresentationCustomizer {
    private let iso: Float
    private let exposureDuration: CMTime

    init(iso: Float, exposureDuration: CMTime) {
        self.iso = iso
        self.exposureDuration = exposureDuration
    }

    /// `@objc(replacementMetadataForPhoto:)` with the explicit ObjC selector so
    /// there's zero risk of Swift name-mangling diverging from what AVFoundation
    /// looks up via `respondsToSelector:`. The protocol method is `@optional`
    /// in the ObjC declaration — Swift doesn't auto-emit ObjC selectors for
    /// optional protocol methods unless the conforming method is marked, and
    /// even with `@objc` alone, leaving the selector implicit can produce a
    /// different stub on some toolchain versions. Hard-coding the selector is
    /// the canonical safe form.
    @objc(replacementMetadataForPhoto:)
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        var exif = (metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        let durationSeconds = CMTimeGetSeconds(exposureDuration)
        if durationSeconds > 0, durationSeconds.isFinite {
            exif[kCGImagePropertyExifExposureTime as String] = durationSeconds
            // ShutterSpeedValue is the APEX-encoded reciprocal of ExposureTime
            // (`-log2(exposureTime)`). Photo viewers display it interchangeably
            // with ExposureTime; patching both keeps third-party EXIF tools
            // consistent with Apple's Photos info pane.
            exif[kCGImagePropertyExifShutterSpeedValue as String] = -log2(durationSeconds)
        }
        if iso > 0 {
            // ISOSpeedRatings is a `[CFNumberRef]` array per CGImageProperties.h.
            // Use `NSNumber` (not `Int`) so the bridge writes the EXIF tag's
            // expected SHORT (UInt16) type — `Int` bridges to NSNumber(long)
            // which some EXIF parsers misread.
            exif[kCGImagePropertyExifISOSpeedRatings as String] = [NSNumber(value: Int(iso.rounded()))]
        }
        metadata[kCGImagePropertyExifDictionary as String] = exif
        return metadata
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PRMPhotoCapture: AVCapturePhotoCaptureDelegate {
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        peek(resolvedSettings.uniqueID)?.willCapture?()
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        finishCapture(photo: photo, error: error)
    }

    #if !os(macOS)
        /// Required when `AVCapturePhotoOutput.isAutoDeferredPhotoDeliveryEnabled` is on.
        /// AVFoundation throws `NSInvalidArgumentException` from `capturePhotoWithSettings:`
        /// if the delegate doesn't respond to this selector while deferred delivery is
        /// enabled — even when the *individual* capture wouldn't actually use it.
        ///
        /// `AVCaptureDeferredPhotoProxy` is a subclass of `AVCapturePhoto`, so the proxy
        /// flows through the same outcome path as a regular photo. The proxy carries a
        /// low-res preview plus enough metadata for the Photos framework to upgrade the
        /// asset to full resolution later when written via `PHAssetResourceType.photoProxy`.
        /// Callers that save through `addResource(with: .photo, ...)` will get only the
        /// proxy bytes — see the type-level doc.
        public func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
            error: Error?
        ) {
            guard let deferredPhotoProxy else {
                // If AVFoundation reports a proxy callback with no proxy, there's no usable
                // payload — the same capture will follow up with a normal
                // `didFinishProcessingPhoto`, so do nothing here and let that path resolve.
                return
            }
            finishCapture(photo: deferredPhotoProxy, error: error)
        }
    #endif

    /// Shared resolution path for both the regular and deferred-proxy delegate callbacks.
    /// Computes outcome under the lock; resumes continuations after unlock so user-visible
    /// work never runs while holding the lock.
    private func finishCapture(photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID

        let outcome: PhotoOutcome = {
            lock.lock()
            defer { lock.unlock() }
            guard let pending = pendingCaptures[id] else { return .ignore }

            if pending.cancelled {
                pendingCaptures.removeValue(forKey: id)
                // For Live Photo: the movie sidecar's URL is owned by us (assigned
                // via `liveSettings.livePhotoMovieFileURL = movieURL`), so we must
                // remove it on cancellation regardless of whether the movie delegate
                // has fired yet. The cancelled-photo path used to leak the file when
                // the movie finished AFTER cancellation — `PhotoOutcome.resume()`
                // only removes the file on the failure branch, but a cancelled photo
                // hits the failure branch here, so this cleanup is now correctly
                // routed by `PhotoOutcome.resume()`. The explicit removal below is
                // defensive: AVFoundation may also call the movie delegate after we
                // remove the pending entry, in which case the file would be orphaned.
                if case let .live(movieURL) = pending.kind {
                    PRMTempFile.remove(movieURL)
                }
                return .terminal(pending, .failure(PRMSessionError.cancelled))
            }
            if let error {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(
                    PRMSessionError.photoCaptureFailed(error.localizedDescription)
                ))
            }
            let originalData: Data? = {
                guard let iso = pending.manualISO,
                      let duration = pending.manualExposureDuration,
                      duration.isValid
                else { return photo.fileDataRepresentation() }
                // Patch EXIF ExposureTime + ISOSpeedRatings + ShutterSpeedValue
                // with the device-snapshot values we recorded at bracket-fire
                // time. AVFoundation writes auto-AE values into the bracket
                // capture's EXIF on iPhone 14 Pro+ even when the frame was
                // captured at manual exposure (Apple dev-forum 120427).
                return Self.fileDataReplacingExposure(
                    photo: photo,
                    iso: iso,
                    exposureDuration: duration
                ) ?? photo.fileDataRepresentation()
            }()
            guard let originalData else {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(
                    PRMSessionError.photoCaptureFailed("No file data representation")
                ))
            }

            let result = renderPhoto(originalData: originalData, photo: photo, pending: pending)

            switch pending.kind {
            case .single:
                return finishSingleSuccess(id: id, pending: pending, result: result)
            case .live:
                return finishLiveSuccess(id: id, pending: pending, result: result)
            }
        }()

        outcome.resume()
    }

    /// Single-photo success path. Removes the pending entry and returns a terminal
    /// outcome carrying the rendered photo. Called with `lock` held by the caller —
    /// mutates `pendingCaptures` directly.
    private func finishSingleSuccess(
        id: Int64,
        pending: PendingCapture,
        result: PRMPhoto
    ) -> PhotoOutcome {
        pendingCaptures.removeValue(forKey: id)
        return .terminal(pending, .success(result))
    }

    /// Live Photo success path. If the movie sidecar has already arrived (or errored),
    /// finalize now; otherwise stash the photo half on the pending entry and tell the
    /// caller we're still waiting for the movie. Called with `lock` held.
    private func finishLiveSuccess(
        id: Int64,
        pending: PendingCapture,
        result: PRMPhoto
    ) -> PhotoOutcome {
        pending.capturedPhoto = result
        // If the movie finished first, complete now.
        guard pending.liveMovieReady || pending.liveMovieError != nil else {
            return .pendingLiveMovie
        }
        pendingCaptures.removeValue(forKey: id)
        if let movieError = pending.liveMovieError {
            return .terminal(pending, .failure(
                PRMSessionError.photoCaptureFailed(movieError.localizedDescription)
            ))
        }
        return .terminal(pending, .success(result))
    }

    #if !os(macOS)
        public func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
            duration: CMTime,
            photoDisplayTime: CMTime,
            resolvedSettings: AVCaptureResolvedPhotoSettings,
            error: Error?
        ) {
            let id = resolvedSettings.uniqueID
            let outcome: PhotoOutcome = {
                lock.lock()
                defer { lock.unlock() }
                guard let pending = pendingCaptures[id], case .live = pending.kind else {
                    // No matching pending capture — either the still path already
                    // resolved (cancellation race) or a stale callback fired after
                    // teardown. Either way, the movie file at `outputFileURL` is
                    // unreferenced now and would orphan in `<tmp>/Prism/` without
                    // explicit cleanup. Removing here closes the window between the
                    // still delegate's removal and a late movie delegate.
                    PRMTempFile.remove(outputFileURL)
                    return .ignore
                }
                pending.liveMovieReady = error == nil
                pending.liveMovieError = error

                // If the photo arrived first, complete now; otherwise wait.
                guard let photo = pending.capturedPhoto else { return .pendingPhoto }
                pendingCaptures.removeValue(forKey: id)
                if let error {
                    return .terminal(pending, .failure(
                        PRMSessionError.photoCaptureFailed(error.localizedDescription)
                    ))
                }
                return .terminal(pending, .success(photo))
            }()
            outcome.resume()
        }
    #endif
}

// MARK: - PhotoOutcome

/// Resolution of a delegate callback against the pending-capture state machine. Computed under
/// the lock; resumed (via `resume()`) after the lock is released.
private enum PhotoOutcome {
    /// No pending capture for this ID (e.g. a duplicate / stale callback) — drop on the floor.
    case ignore
    /// Waiting for the Live Photo movie sidecar to finish.
    case pendingLiveMovie
    /// Waiting for the Live Photo still to finish.
    case pendingPhoto
    /// Both halves have arrived (or one half failed) — resume the continuation.
    case terminal(PRMPhotoCapture.PendingCapture, Result<PRMPhoto, Error>)

    func resume() {
        guard case let .terminal(pending, result) = self else { return }
        // Take-and-nil before resuming so any second arrival on this PendingCapture
        // (in-flight delegate callbacks racing the cancellation/error path, or future
        // logic errors that reach `.terminal` twice for the same entry) silently
        // no-ops. `CheckedContinuation.resume` crashes the process on double-resume,
        // so the cost of belt-and-suspenders here is one optional take and we lose
        // nothing in exchange.
        switch pending.kind {
        case .single:
            guard let continuation = pending.singleContinuation else { return }
            pending.singleContinuation = nil
            switch result {
            case let .success(photo):
                continuation.resume(returning: photo)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        case let .live(movieURL):
            guard let continuation = pending.liveContinuation else {
                if case .failure = result {
                    PRMTempFile.remove(movieURL)
                }
                return
            }
            pending.liveContinuation = nil
            switch result {
            case let .success(photo):
                continuation.resume(
                    returning: PRMLivePhoto(photo: photo, movieURL: movieURL)
                )
            case let .failure(error):
                PRMTempFile.remove(movieURL)
                continuation.resume(throwing: error)
            }
        }
    }
}
