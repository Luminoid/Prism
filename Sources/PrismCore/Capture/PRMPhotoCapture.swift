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
        } onCancel: {
            self.markCancelled(avSettings.uniqueID)
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
            } onCancel: {
                self.markCancelled(liveSettings.uniqueID)
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

    fileprivate enum PendingKind {
        case single
        case live(movieURL: URL)
    }

    fileprivate final class PendingCapture {
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
        // For single captures we resume here; for live we stash and wait for the movie.
        lock.lock()
        guard let pending = pendingCaptures[id] else {
            lock.unlock()
            return
        }

        if pending.cancelled {
            pendingCaptures.removeValue(forKey: id)
            lock.unlock()
            switch pending.kind {
            case .single:
                pending.singleContinuation?.resume(throwing: PRMSessionError.cancelled)
            case let .live(movieURL):
                PRMTempFile.remove(movieURL)
                pending.liveContinuation?.resume(throwing: PRMSessionError.cancelled)
            }
            return
        }
        if let error {
            pendingCaptures.removeValue(forKey: id)
            lock.unlock()
            switch pending.kind {
            case .single:
                pending.singleContinuation?.resume(
                    throwing: PRMSessionError.photoCaptureFailed(error.localizedDescription)
                )
            case let .live(movieURL):
                PRMTempFile.remove(movieURL)
                pending.liveContinuation?.resume(
                    throwing: PRMSessionError.photoCaptureFailed(error.localizedDescription)
                )
            }
            return
        }
        guard let originalData = photo.fileDataRepresentation() else {
            pendingCaptures.removeValue(forKey: id)
            lock.unlock()
            switch pending.kind {
            case .single:
                pending.singleContinuation?.resume(
                    throwing: PRMSessionError.photoCaptureFailed("No file data representation")
                )
            case let .live(movieURL):
                PRMTempFile.remove(movieURL)
                pending.liveContinuation?.resume(
                    throwing: PRMSessionError.photoCaptureFailed("No file data representation")
                )
            }
            return
        }

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

        let result = PRMPhoto(
            data: finalData,
            underlyingPhoto: photo,
            metadata: metadata
        )

        switch pending.kind {
        case .single:
            pendingCaptures.removeValue(forKey: id)
            lock.unlock()
            pending.singleContinuation?.resume(returning: result)
        case let .live(movieURL):
            pending.capturedPhoto = result
            // If the movie finished first, complete now.
            if pending.liveMovieReady || pending.liveMovieError != nil {
                pendingCaptures.removeValue(forKey: id)
                let movieError = pending.liveMovieError
                lock.unlock()
                if let movieError {
                    PRMTempFile.remove(movieURL)
                    pending.liveContinuation?.resume(
                        throwing: PRMSessionError.photoCaptureFailed(movieError.localizedDescription)
                    )
                } else {
                    pending.liveContinuation?.resume(
                        returning: PRMLivePhoto(photo: result, movieURL: movieURL)
                    )
                }
            } else {
                lock.unlock()
            }
        }
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
            lock.lock()
            guard let pending = pendingCaptures[id], case let .live(movieURL) = pending.kind else {
                lock.unlock()
                return
            }
            pending.liveMovieReady = error == nil
            pending.liveMovieError = error

            // If the photo arrived first, complete now.
            if let photo = pending.capturedPhoto {
                pendingCaptures.removeValue(forKey: id)
                lock.unlock()
                if let error {
                    PRMTempFile.remove(movieURL)
                    pending.liveContinuation?.resume(
                        throwing: PRMSessionError.photoCaptureFailed(error.localizedDescription)
                    )
                } else {
                    pending.liveContinuation?.resume(
                        returning: PRMLivePhoto(photo: photo, movieURL: movieURL)
                    )
                }
            } else {
                lock.unlock()
            }
        }
    #endif
}
