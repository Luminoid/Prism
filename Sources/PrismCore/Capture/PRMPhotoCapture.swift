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
/// ```swift
/// let capturer = PRMPhotoCapture(output: photoOutput)
/// let photo = try await capturer.capturePhoto(
///     settings: PRMPhotoSettings().flashMode(.auto),
///     applying: SepiaFilter(intensity: 0.8),
///     context: renderContext
/// )
/// // photo.data is filtered JPEG with original EXIF preserved
/// ```
public final class PRMPhotoCapture: NSObject, @unchecked Sendable {
    // MARK: - Properties

    public let output: AVCapturePhotoOutput

    /// Pending captures keyed by resolved settings ID.
    private var pendingCaptures: [Int64: PendingCapture] = [:]
    private let lock = NSLock()

    // MARK: - Init

    public init(output: AVCapturePhotoOutput) {
        self.output = output
        super.init()
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
        let avSettings = settings.makeAVSettings()
        clampFlashMode(on: avSettings)
        let pending = PendingCapture(
            kind: .single,
            filterRecipe: filterRecipe,
            filterCodec: settings.codec,
            willCapture: willCapture
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.singleContinuation = continuation
                lock.lock()
                pendingCaptures[avSettings.uniqueID] = pending
                lock.unlock()
                output.capturePhoto(with: avSettings, delegate: self)
            }
        } onCancel: { [weak self] in
            self?.markCancelled(avSettings.uniqueID)
        }
    }

    /// Force `AVCapturePhotoSettings.flashMode` into a value the current photo output
    /// actually supports. `AVCapturePhotoOutput.supportedFlashModes` changes per device
    /// (front camera has no flash hardware) and per session preset; setting `flashMode`
    /// to a mode not in that list silently drops to `.off` with no warning, which makes
    /// "Auto flash isn't firing" look like a Prism bug when it's really an unsupported
    /// request. When `.auto` is unsupported we fall through to `.on` (closest behavioral
    /// match — "fire flash when shutter opens"), then `.off` as a last resort.
    private func clampFlashMode(on settings: AVCapturePhotoSettings) {
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
            guard output.isLivePhotoCaptureSupported, output.isLivePhotoCaptureEnabled else {
                throw PRMSessionError.photoCaptureFailed(
                    "Live Photo is not enabled on the photo output. Set enableLivePhoto on PRMCameraConfiguration."
                )
            }
            let liveSettings = settings.livePhoto(true).makeAVSettings()
            clampFlashMode(on: liveSettings)
            let movieURL = PRMTempFile.url(withExtension: "mov")
            liveSettings.livePhotoMovieFileURL = movieURL

            let pending = PendingCapture(
                kind: .live(movieURL: movieURL),
                filterRecipe: .none,
                willCapture: willCapture
            )

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.liveContinuation = continuation
                    lock.lock()
                    pendingCaptures[liveSettings.uniqueID] = pending
                    lock.unlock()
                    output.capturePhoto(with: liveSettings, delegate: self)
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
            willCapture: (@Sendable () -> Void)?
        ) {
            self.kind = kind
            self.filterRecipe = filterRecipe
            self.filterCodec = filterCodec
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
    private static func encodeFilteredImage(
        _ image: CIImage,
        preservedProperties: [String: Any],
        codec: AVVideoCodecType?,
        context: PRMRenderContext
    ) -> Data? {
        if codec == .hevc || codec == .hevcWithAlpha {
            if let heif = PRMImage.heifDataPreservingMetadata(
                from: image,
                originalProperties: preservedProperties,
                context: context
            ) {
                return heif
            }
        }
        return PRMImage.jpegDataPreservingMetadata(
            from: image,
            originalProperties: preservedProperties,
            context: context
        )
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
                return .terminal(pending, .failure(PRMSessionError.cancelled))
            }
            if let error {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(
                    PRMSessionError.photoCaptureFailed(error.localizedDescription)
                ))
            }
            guard let originalData = photo.fileDataRepresentation() else {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(
                    PRMSessionError.photoCaptureFailed("No file data representation")
                ))
            }

            let result = renderPhoto(originalData: originalData, photo: photo, pending: pending)

            switch pending.kind {
            case .single:
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .success(result))
            case .live:
                pending.capturedPhoto = result
                // If the movie finished first, complete now.
                if pending.liveMovieReady || pending.liveMovieError != nil {
                    pendingCaptures.removeValue(forKey: id)
                    if let movieError = pending.liveMovieError {
                        return .terminal(pending, .failure(
                            PRMSessionError.photoCaptureFailed(movieError.localizedDescription)
                        ))
                    } else {
                        return .terminal(pending, .success(result))
                    }
                }
                return .pendingLiveMovie
            }
        }()

        outcome.resume()
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
        switch pending.kind {
        case .single:
            switch result {
            case let .success(photo):
                pending.singleContinuation?.resume(returning: photo)
            case let .failure(error):
                pending.singleContinuation?.resume(throwing: error)
            }
        case let .live(movieURL):
            switch result {
            case let .success(photo):
                pending.liveContinuation?.resume(
                    returning: PRMLivePhoto(photo: photo, movieURL: movieURL)
                )
            case let .failure(error):
                PRMTempFile.remove(movieURL)
                pending.liveContinuation?.resume(throwing: error)
            }
        }
    }
}
