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
        let avSettings = settings.makeAVSettings()
        let pending = PendingCapture(
            kind: .single,
            filter: filter,
            context: context,
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
            let movieURL = PRMTempFile.url(withExtension: "mov")
            liveSettings.livePhotoMovieFileURL = movieURL

            let pending = PendingCapture(
                kind: .live(movieURL: movieURL),
                filter: nil,
                context: nil,
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
    public func captureBurst(
        count: Int,
        settings: PRMPhotoSettings = PRMPhotoSettings(),
        willCapture: (@Sendable () -> Void)? = nil
    ) async throws -> [PRMPhoto] {
        guard count > 0 else { return [] }
        return try await withThrowingTaskGroup(of: (Int, PRMPhoto).self) { group in
            for index in 0 ..< count {
                group.addTask {
                    let photo = try await self.capturePhoto(
                        settings: settings,
                        willCapture: index == 0 ? willCapture : nil
                    )
                    return (index, photo)
                }
            }
            var results: [(Int, PRMPhoto)] = []
            for try await pair in group {
                results.append(pair)
            }
            results.sort { $0.0 < $1.0 }
            return results.map(\.1)
        }
    }

    // MARK: - Pending tracker

    enum PendingKind {
        case single
        case live(movieURL: URL)
    }

    final class PendingCapture {
        let kind: PendingKind
        let filter: (any PRMFilter)?
        let context: PRMRenderContext?
        let willCapture: (@Sendable () -> Void)?
        var singleContinuation: CheckedContinuation<PRMPhoto, Error>?
        var liveContinuation: CheckedContinuation<PRMLivePhoto, Error>?
        var cancelled: Bool = false
        var capturedPhoto: PRMPhoto?
        var liveMovieReady: Bool = false
        var liveMovieError: Error?

        init(
            kind: PendingKind,
            filter: (any PRMFilter)?,
            context: PRMRenderContext?,
            willCapture: (@Sendable () -> Void)?
        ) {
            self.kind = kind
            self.filter = filter
            self.context = context
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
        if let filter = pending.filter, let context = pending.context, let sourceImage = CIImage(data: originalData) {
            let filtered = filter.render(sourceImage)
            let preservedProperties = sourceImage.properties.merging(metadata) { _, new in new }
            finalData = PRMImage.jpegDataPreservingMetadata(
                from: filtered,
                originalProperties: preservedProperties,
                context: context
            ) ?? originalData
        } else {
            finalData = originalData
        }
        return PRMPhoto(data: finalData, underlyingPhoto: photo, metadata: metadata)
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
        let id = photo.resolvedSettings.uniqueID

        // Compute the outcome (and dequeue if final) under the lock; *resume* continuations
        // after unlock so we never hold the lock across user-visible work.
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
