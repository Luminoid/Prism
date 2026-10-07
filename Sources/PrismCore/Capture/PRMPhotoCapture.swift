@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO

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
/// its lifetime. Captures will fail at the AVFoundation gate if Prism later detaches
/// that output. Keep only if you own the output yourself and it will never be replaced.
///
/// ```swift
/// let capturer = PRMPhotoCapture(output: photoOutput)
/// ```
///
/// Every capture entry point waits for the output to be ready (see ``capturePhoto(settings:applying:context:willCapture:)``)
/// and only then builds its `AVCapturePhotoSettings`, against the output's state at that
/// moment: a reconfigure during the wait can't leave settings the output would reject.
public final class PRMPhotoCapture: NSObject, @unchecked Sendable {
    // MARK: - Properties

    private let resolver: PRMOutputResolver<AVCapturePhotoOutput>

    /// The output the wrapper was constructed against (legacy init) or — for the
    /// session-based init — the output the most recent capture resolved, `nil` before the
    /// first one. Captures resolve the live output themselves; this may be stale between
    /// captures.
    public var output: AVCapturePhotoOutput? {
        resolver.latest
    }

    /// Pending captures keyed by resolved settings ID. Guarded by `lock`.
    var pendingCaptures: [Int64: PendingCapture] = [:]
    let lock = NSLock()

    /// How long a capture waits for the photo output to finish rebuilding after a
    /// reconfigure. 3 s covers the Triple-Camera-after-slow-motion rebuild observed on
    /// hardware; past it the session needs reconfiguring.
    static let readinessTimeout: TimeInterval = 3

    // MARK: - Init

    /// Legacy init. The wrapper is bound to `output` permanently — if Prism later
    /// detaches that output (e.g. on a Live-Photo-recovery reconfigure after a
    /// virtual-device swap), every capture will fail at the AVFoundation gate. Prefer
    /// ``init(session:)`` for any session that may reconfigure.
    public init(output: AVCapturePhotoOutput) {
        resolver = PRMOutputResolver(fixed: output)
        super.init()
    }

    /// Session-based init. The wrapper resolves `session.photoOutput` at every
    /// capture entry point, so reconfigure-driven output replacements (Live-Photo
    /// recovery on virtual devices, format-swap-driven rebuilds of the secondary
    /// movie pipeline) are invisible to the caller.
    ///
    /// Capture entry points throw ``PRMSessionError/photoCaptureFailed(_:)`` if the
    /// session has no photo output attached at capture time.
    public init(session: PRMCameraSession) {
        resolver = PRMOutputResolver { [weak session] in
            guard let session else { return nil }
            return await session.photoOutput
        }
        super.init()
    }

    // MARK: - Capture

    /// Captures a photo, optionally applying a filter before encoding.
    ///
    /// Waits up to 3 s for the photo output to be ready first: an enabled, active video
    /// connection, `captureReadiness == .ready` and non-zero `maxPhotoDimensions`. After a
    /// Live Photo toggle, camera switch or format change on a virtual device that rebuild
    /// outlasts `commitConfiguration` by seconds, and capturing during it raises
    /// `NSInvalidArgumentException` ("No active and enabled video connection"), which Swift
    /// can't catch. The wait throws ``PRMSessionError/photoCaptureFailed(_:)`` on timeout
    /// instead.
    ///
    /// - Parameters:
    ///   - settings: Builder for `AVCapturePhotoSettings`.
    ///   - filter: Optional filter; when non-nil, the captured data is re-encoded through it.
    ///   - context: Render context for the filter encode; ``PRMRenderContext/shared`` when nil.
    ///   - willCapture: Called the moment the shutter fires (for animation).
    /// - Returns: A ``PRMPhoto`` with encoded data + metadata.
    /// - Throws: ``PRMSessionError/cancelled`` when the task is cancelled before the photo
    ///   arrives, ``PRMSessionError/captureFailed(_:)`` with AVFoundation's error, or
    ///   ``PRMSessionError/photoCaptureFailed(_:)``.
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

    /// Common path for every still capture. `portrait` adds depth, portrait-matte and HEVC
    /// requests based on what the live output delivers (see
    /// ``capturePortraitPhoto(settings:applying:context:willCapture:)``).
    func capturePhoto(
        settings requested: PRMPhotoSettings,
        filterRecipe: FilterRecipe,
        willCapture: (@Sendable () -> Void)?,
        portrait: Bool = false
    ) async throws -> PRMPhoto {
        let liveOutput = try await resolveCurrentOutput()
        try await waitUntilReady(liveOutput)
        let settings = portrait ? Self.portraitSettings(from: requested, output: liveOutput) : requested
        let dims = liveOutput.maxPhotoDimensions
        PRMLog.debug(
            .capture,
            "capturePhoto entry: maxDim=\(dims.width)×\(dims.height), live=\(liveOutput.isLivePhotoCaptureEnabled), depth=\(liveOutput.isDepthDataDeliveryEnabled), portrait=\(portrait)"
        )
        let prepared = prepareStillSettings(settings, output: liveOutput)
        await Self.applyRotation(settings.rotationAngle, to: liveOutput)
        let pending = PendingCapture(
            kind: .single,
            filterRecipe: filterRecipe,
            filterCodec: settings.codec,
            manualISO: prepared.manualISO,
            manualExposureDuration: prepared.manualDuration,
            willCapture: willCapture
        )
        return try await fire(prepared.settings, on: liveOutput, pending: pending) { pending, continuation in
            pending.singleContinuation = continuation
        }
    }

    /// Captures a Live Photo: still image + paired movie. Both must finish before this
    /// returns. Throws if the photo output was not configured with
    /// ``PRMCameraConfiguration/enableLivePhoto`` set to `true`, if Live Photo is turned
    /// off on the output, or if AVFoundation has suspended it (for example while recording).
    ///
    /// The movie sidecar is written to a unique URL under `<tmp>/Prism/`. The caller is
    /// responsible for moving or deleting the file (consumers typically save both pieces
    /// to `PHPhotoLibrary` as a paired resource).
    ///
    /// Manual exposure doesn't apply here: AVFoundation drops custom exposure while Live
    /// Photo is enabled on the output, so turn Live Photo off for manual captures.
    public func captureLivePhoto(
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> PRMLivePhoto {
        let liveOutput = try await resolveCurrentOutput()
        try await waitUntilReady(liveOutput)
        let supported = liveOutput.isLivePhotoCaptureSupported
        let enabled = liveOutput.isLivePhotoCaptureEnabled
        let suspended = liveOutput.isLivePhotoCaptureSuspended
        guard supported, enabled, !suspended else {
            PRMLog.error(
                .capture,
                "captureLivePhoto: refused — supported=\(supported), enabled=\(enabled), suspended=\(suspended)"
            )
            throw PRMSessionError.photoCaptureFailed(
                "Live Photo isn't available on the photo output (supported=\(supported), enabled=\(enabled), suspended=\(suspended)). Call camera.setLivePhotoCaptureEnabled(true)."
            )
        }
        PRMLog.debug(.capture, "captureLivePhoto entry")
        let liveSettings = settings.makeAVSettings(for: liveOutput)
        clampFlashMode(on: liveSettings, output: liveOutput)
        applyManualExposureOverrides(on: liveSettings, output: liveOutput)
        await Self.applyRotation(settings.rotationAngle, to: liveOutput)
        let movieURL = PRMTempFile.url(withExtension: "mov")
        liveSettings.livePhotoMovieFileURL = movieURL

        let pending = PendingCapture(
            kind: .live(movieURL: movieURL),
            filterRecipe: .none,
            willCapture: willCapture
        )
        return try await fire(liveSettings, on: liveOutput, pending: pending) { pending, continuation in
            pending.liveContinuation = continuation
        }
    }

    /// Captures a burst of `count` photos, one after another: each shot starts once the
    /// previous photo has been delivered. Use sparingly — large bursts hold many photos in
    /// memory. ``PRMCameraConfiguration/enableResponsiveCapture`` shortens the gap.
    ///
    /// - Throws: The first shot's error when it fails. When a later shot fails (or the task
    ///   is cancelled mid-burst), ``PRMBurstInterruptedError`` carrying the photos already
    ///   captured, so they aren't lost.
    public func captureBurst(
        count: Int,
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> [PRMPhoto] {
        PRMLog.debug(.capture, "captureBurst entry: count=\(count)")
        guard count > 0 else { return [] }
        var results: [PRMPhoto] = []
        results.reserveCapacity(count)
        for index in 0 ..< count {
            do {
                let photo = try await capturePhoto(
                    settings: settings,
                    willCapture: index == 0 ? willCapture : nil
                )
                results.append(photo)
            } catch {
                guard !results.isEmpty else { throw error }
                PRMLog.notice(.capture, "Burst stopped after \(results.count) of \(count) photos")
                throw PRMBurstInterruptedError(capturedPhotos: results, underlyingError: error)
            }
        }
        PRMLog.notice(.capture, "Burst captured \(results.count) photos")
        return results
    }

    // MARK: - Pre-flight

    /// Returns the live `AVCapturePhotoOutput` per the configured resolver.
    ///
    /// Throws ``PRMSessionError/photoCaptureFailed(_:)`` when the session-based resolver
    /// returns nil — i.e. the consuming app hasn't attached a photo output to the session
    /// (`setPhotoOutputAttached(true)`) or the session has been torn down.
    private func resolveCurrentOutput() async throws -> AVCapturePhotoOutput {
        guard let resolved = await resolver.resolve() else {
            PRMLog.error(.capture, "No photo output attached to the session; capture refused")
            throw PRMSessionError.photoCaptureFailed(
                "AVCapturePhotoOutput is not attached to the session — call setPhotoOutputAttached(true) before capturing"
            )
        }
        return resolved
    }

    /// Polls the output's readiness every 50 ms (see ``AVCapturePhotoOutput/PRMReadiness``)
    /// until it's ready, re-applying a `(0, 0)` photo ceiling on the way. Throws
    /// ``PRMSessionError/photoCaptureFailed(_:)`` at the timeout and
    /// ``PRMSessionError/cancelled`` when the task is cancelled.
    private func waitUntilReady(_ output: AVCapturePhotoOutput, timeout: TimeInterval = PRMPhotoCapture.readinessTimeout) async throws {
        let pollStep: UInt64 = 50_000_000
        let deadline = Date().addingTimeInterval(timeout)
        var readiness = output.prm_readiness
        while !readiness.isReady {
            if let healed = output.prm_healMaxPhotoDimensionsIfNeeded() {
                PRMLog.notice(.capture, "Re-applied photo maxDimensions \(healed.width)×\(healed.height) after the output rebuilt")
            }
            guard Date() < deadline else {
                PRMLog.error(.capture, "Photo output not ready after \(Int(timeout * 1000)) ms (\(readiness.summary)); capture refused")
                throw PRMSessionError.photoCaptureFailed(
                    "AVCapturePhotoOutput not ready after \(Int(timeout * 1000)) ms (\(readiness.summary)) — the session may need to be reconfigured"
                )
            }
            do {
                try await Task.sleep(nanoseconds: pollStep)
            } catch {
                throw PRMSessionError.cancelled
            }
            readiness = output.prm_readiness
        }
        if Task.isCancelled {
            throw PRMSessionError.cancelled
        }
    }

    /// Sets the photo connection's rotation on the camera actor, so it can't interleave with
    /// a session reconfigure. No-op for `nil` or an unsupported angle.
    @PRMCameraActor
    private static func applyRotation(_ angle: CGFloat?, to output: AVCapturePhotoOutput) {
        guard let angle, let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Firing

    /// Registers `pending`, fires the capture, and suspends until the delegate settles it.
    /// A task cancelled before registration (whose `onCancel` found nothing to flag) is
    /// caught here and never fires the shutter.
    private func fire<Value>(
        _ avSettings: AVCapturePhotoSettings,
        on output: AVCapturePhotoOutput,
        pending: PendingCapture,
        install: @escaping (PendingCapture, CheckedContinuation<Value, any Error>) -> Void
    ) async throws -> Value {
        let id = avSettings.uniqueID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                install(pending, continuation)
                lock.lock()
                pendingCaptures[id] = pending
                lock.unlock()
                if Task.isCancelled {
                    lock.lock()
                    pendingCaptures.removeValue(forKey: id)
                    lock.unlock()
                    PhotoOutcome.terminal(pending, .failure(PRMSessionError.cancelled)).resume()
                    return
                }
                output.capturePhoto(with: avSettings, delegate: self)
            }
        } onCancel: { [weak self] in
            self?.markCancelled(id)
        }
    }

    // MARK: - Settings

    /// The settings to fire plus the manual values to patch into EXIF.
    private struct PreparedSettings {
        let settings: AVCapturePhotoSettings
        let manualISO: Float?
        let manualDuration: CMTime?
    }

    /// Builds the settings against the output as it is now (after the readiness wait).
    ///
    /// Manual exposure (an override, or a device in `.custom`) goes through a single-frame
    /// `AVCapturePhotoBracketSettings`: brackets disable Smart HDR, Deep Fusion and
    /// virtual-device fusion, which otherwise overwrite manual ISO and shutter (the
    /// AVCamManual approach). Everything else uses regular settings, and so does manual
    /// exposure when no bracket can fire (see ``manualBracketBlocker(device:output:)``):
    /// the photo then takes the device's own exposure, and the EXIF is patched only when
    /// that exposure is manual.
    private func prepareStillSettings(_ settings: PRMPhotoSettings, output: AVCapturePhotoOutput) -> PreparedSettings {
        let device = output.prm_sourceDevice
        let override = settings.manualExposureOverride.flatMap { Self.clampedExposure($0, for: device) }
        let deviceInCustom = device?.exposureMode == .custom
        if override != nil || deviceInCustom {
            guard let blocker = Self.manualBracketBlocker(device: device, output: output) else {
                return manualBracketSettings(settings, override: override, device: device, output: output)
            }
            PRMLog.notice(.capture, "Manual exposure without a bracket (\(blocker)); capturing at the device's exposure")
        }
        let regular = settings.makeAVSettings(for: output)
        clampFlashMode(on: regular, output: output)
        applyManualExposureOverrides(on: regular, output: output)
        let exifPatch = deviceInCustom ? override : nil
        return PreparedSettings(settings: regular, manualISO: exifPatch?.iso, manualDuration: exifPatch?.duration)
    }

    /// Why a manual-exposure bracket can't fire on `output` now, `nil` when it can. Firing one
    /// anyway raises `NSInvalidArgumentException`, which Swift can't catch.
    static func manualBracketBlocker(device: AVCaptureDevice?, output: AVCapturePhotoOutput) -> String? {
        guard output.maxBracketedCapturePhotoCount >= 1 else { return "the output allows no bracketed capture" }
        guard let device else { return "no camera is connected to the output" }
        guard device.prm_supportsManualExposureCapture else {
            return "\(device.deviceType.rawValue) can't take a manual exposure"
        }
        return nil
    }

    /// A single-frame manual bracket. Override values are already clamped to the active
    /// format (the bracket raises on out-of-range ISO or duration); without an override the
    /// `currentISO` / `currentExposureDuration` sentinels let AVFoundation resolve them at
    /// fire time.
    private func manualBracketSettings(
        _ settings: PRMPhotoSettings,
        override: (iso: Float, duration: CMTime)?,
        device: AVCaptureDevice?,
        output: AVCapturePhotoOutput
    ) -> PreparedSettings {
        let processedFormat: [String: Any]? = if let codec = settings.codec,
                                                 output.availablePhotoCodecTypes.contains(codec) {
            [AVVideoCodecKey: codec]
        } else {
            nil
        }
        let bracketed = AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
            exposureDuration: override?.duration ?? AVCaptureDevice.currentExposureDuration,
            iso: override?.iso ?? AVCaptureDevice.currentISO
        )
        let bracket = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: processedFormat,
            bracketedSettings: [bracketed]
        )
        bracket.photoQualityPrioritization = PRMPhotoSettings.clampedQuality(
            bracket.photoQualityPrioritization,
            max: output.maxPhotoQualityPrioritization
        )
        if let requested = settings.maxDimensions,
           let dimensions = PRMPhotoSettings.validatedMaxDimensions(
               requested,
               supported: device?.activeFormat.supportedMaxPhotoDimensions ?? [],
               ceiling: output.maxPhotoDimensions
           ) {
            bracket.maxPhotoDimensions = dimensions
        }
        if settings.depthDataDelivery == true || settings.portraitEffectsMatte == true {
            PRMLog.notice(.capture, "Depth and portrait matte aren't delivered with manual exposure (bracketed capture)")
        }
        // EXIF patch: the override values, or what the device reports right before firing.
        let iso = override?.iso ?? device?.iso
        let duration = override?.duration ?? device?.exposureDuration
        return PreparedSettings(settings: bracket, manualISO: iso, manualDuration: duration)
    }

    /// `exposure` clamped to the device's active format, `nil` without a device to clamp
    /// against (the bracket then uses the "current" sentinels). An axis that isn't a usable
    /// value (a sentinel, zero, NaN) becomes `currentISO` / `currentExposureDuration`.
    static func clampedExposure(_ exposure: (iso: Float, duration: CMTime), for device: AVCaptureDevice?) -> (iso: Float, duration: CMTime)? {
        guard let device else { return nil }
        let format = device.activeFormat
        let iso = exposure.iso.isFinite && exposure.iso > 0
            ? min(max(exposure.iso, format.minISO), format.maxISO)
            : AVCaptureDevice.currentISO
        let duration = exposure.duration.isNumeric && CMTimeGetSeconds(exposure.duration) > 0
            ? device.prm_clampedDuration(exposure.duration)
            : AVCaptureDevice.currentExposureDuration
        return (iso, duration)
    }

    /// When the active capture device is in manual exposure (`.custom`), `.locked`
    /// exposure, or locked WB, downgrade `photoQualityPrioritization` to `.speed`
    /// for this capture. AVFoundation's `.balanced` and `.quality` pipelines run
    /// multi-frame fusion (Deep Fusion, Smart HDR) that **fuse several
    /// differently-exposed images**: the captured photo's EXIF shows fused/averaged ISO
    /// and shutter, not the values the user set via `setExposureModeCustom`. `.speed` is
    /// documented as WYSIWYG — "lightly processed only with some noise reduction applied"
    /// per WWDC21 session 10247 — and is the only mode that honors a manual exposure
    /// exactly. It also bypasses the deferred-proxy path, whose later upgrade could drift
    /// from the manual values. The same holds for locked WB, where fusion can blend frames
    /// with re-metered white balance.
    ///
    /// The manual mode wins over a caller's `.balanced` / `.quality`: the user would not
    /// understand "I set ISO 800 and the photo shows ISO 200". In continuous-auto the
    /// caller's choice stands.
    private func applyManualExposureOverrides(on settings: AVCapturePhotoSettings, output: AVCapturePhotoOutput) {
        guard let device = output.prm_sourceDevice else { return }
        let exposureIsManual = device.exposureMode == .custom || device.exposureMode == .locked
        let whiteBalanceIsLocked = device.whiteBalanceMode == .locked
        guard exposureIsManual || whiteBalanceIsLocked else { return }
        settings.photoQualityPrioritization = .speed
        PRMLog.debug(.capture, "Manual exposure / locked WB at capture time — photoQualityPrioritization set to .speed")
    }

    /// Force `AVCapturePhotoSettings.flashMode` into a value the current photo output
    /// actually supports. `AVCapturePhotoOutput.supportedFlashModes` changes per device
    /// (front camera has no flash hardware) and per session preset; setting `flashMode`
    /// to a mode not in that list silently drops to `.off` with no warning, which makes
    /// "Auto flash isn't firing" look like a Prism bug when it's really an unsupported
    /// request. When `.auto` is unsupported we fall through to `.on` (closest behavioral
    /// match — "fire flash when shutter opens"), then `.off` as a last resort.
    private func clampFlashMode(on settings: AVCapturePhotoSettings, output: AVCapturePhotoOutput) {
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

    /// Portrait requests based on what `output` delivers now: HEVC (Photos shows the
    /// Portrait badge and depth slider only for HEIC files with Apple's depth aux, and every
    /// Portrait-capable device has the encoder), embedded depth when depth delivery is on,
    /// and the embedded matte when matte delivery is on (an embedded matte requires embedded
    /// depth). Reading a stale output here would request depth from an output that no longer
    /// delivers it, which raises.
    static func portraitSettings(from settings: PRMPhotoSettings, output: AVCapturePhotoOutput) -> PRMPhotoSettings {
        var portrait = settings
        if portrait.codec == nil, output.availablePhotoCodecTypes.contains(.hevc) {
            portrait = portrait.codec(.hevc)
        }
        if output.isDepthDataDeliveryEnabled {
            portrait = portrait
                .depthDataDelivery(true)
                .embedsDepthDataInPhoto(true)
        }
        if output.isDepthDataDeliveryEnabled, output.isPortraitEffectsMatteDeliveryEnabled {
            portrait = portrait
                .portraitEffectsMatte(true)
                .embedsPortraitEffectsMatteInPhoto(true)
        }
        return portrait
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
        /// Manual ISO and exposure duration to patch into the photo's EXIF in
        /// `finishCapture`. AVFoundation's bracket path on iPhone 14 Pro+ writes the auto-AE
        /// values into EXIF even when the frame was captured at manual exposure (Apple
        /// dev-forum 120427), so the values the capture was fired with are written back via
        /// `fileDataRepresentation(with:)`.
        let manualISO: Float?
        let manualExposureDuration: CMTime?
        var singleContinuation: CheckedContinuation<PRMPhoto, any Error>?
        var liveContinuation: CheckedContinuation<PRMLivePhoto, any Error>?
        var cancelled: Bool = false
        var capturedPhoto: PRMPhoto?
        var liveMovieReady: Bool = false
        var liveMovieError: (any Error)?

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

    func peek(_ id: Int64) -> PendingCapture? {
        lock.lock()
        defer { lock.unlock() }
        return pendingCaptures[id]
    }

    private func markCancelled(_ id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        pendingCaptures[id]?.cancelled = true
    }
}

/// Thrown by ``PRMPhotoCapture/captureBurst(count:settings:willCapture:)`` when a shot after
/// the first fails or the task is cancelled: carries the photos already captured and the
/// error that stopped the burst.
public struct PRMBurstInterruptedError: Error, Sendable {
    /// Photos captured before the burst stopped, in order.
    public let capturedPhotos: [PRMPhoto]
    /// Why the burst stopped (``PRMSessionError/cancelled`` for a cancelled task).
    public let underlyingError: any Error

    public init(capturedPhotos: [PRMPhoto], underlyingError: any Error) {
        self.capturedPhotos = capturedPhotos
        self.underlyingError = underlyingError
    }
}

extension PRMBurstInterruptedError: LocalizedError {
    public var errorDescription: String? {
        "Burst stopped after \(capturedPhotos.count) photos: \(underlyingError.localizedDescription)"
    }
}
