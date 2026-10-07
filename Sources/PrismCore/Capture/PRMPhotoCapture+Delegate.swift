@preconcurrency import AVFoundation
import Foundation

// MARK: - AVCapturePhotoCaptureDelegate

//
// Each capture is settled by exactly one terminal outcome. `photoOutput(_:didFinishCaptureFor:error:)`
// always arrives last, so anything still pending then (a deferred proxy that came back
// empty, a Live Photo whose movie never arrived) is failed there instead of hanging.

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
        error: (any Error)?
    ) {
        finishCapture(photo: photo, error: error)
    }

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
    /// proxy bytes.
    ///
    /// This callback replaces `didFinishProcessingPhoto` for a deferred capture, so a nil
    /// proxy is a failure with no follow-up; the capture is identified (and failed) in
    /// `didFinishCaptureFor`, which carries the resolved settings this callback lacks.
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
        error: (any Error)?
    ) {
        guard let deferredPhotoProxy else {
            PRMLog.error(.capture, "Deferred photo proxy missing", error: error)
            return
        }
        finishCapture(photo: deferredPhotoProxy, error: error)
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
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
                // explicit cleanup.
                PRMTempFile.remove(outputFileURL)
                return .ignore
            }
            pending.liveMovieReady = error == nil
            pending.liveMovieError = error

            // If the photo arrived first, complete now; otherwise wait.
            guard let photo = pending.capturedPhoto else { return .pendingPhoto }
            pendingCaptures.removeValue(forKey: id)
            if let error {
                PRMLog.error(.capture, "Live Photo \(id): movie half failed", error: error)
                return .terminal(pending, .failure(Self.sessionError(for: error)))
            }
            return .terminal(pending, .success(photo))
        }()
        outcome.resume()
    }

    /// Always the last callback for a capture. Fails whatever is still pending: a deferred
    /// capture whose proxy came back nil, a Live Photo whose movie never arrived, or a
    /// capture AVFoundation abandoned.
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        let id = resolvedSettings.uniqueID
        let stranded: PendingCapture? = {
            lock.lock()
            defer { lock.unlock() }
            return pendingCaptures.removeValue(forKey: id)
        }()
        guard let stranded else { return }
        let failure: any Error = if stranded.cancelled {
            PRMSessionError.cancelled
        } else if let error {
            Self.sessionError(for: error)
        } else {
            PRMSessionError.photoCaptureFailed("The capture finished without delivering a photo")
        }
        PRMLog.error(.capture, "Photo capture \(id) finished with nothing delivered", error: error)
        PhotoOutcome.terminal(stranded, .failure(failure)).resume()
    }

    // MARK: - Settling

    /// Shared path for the regular and deferred-proxy callbacks. Takes the pending entry
    /// under the lock, encodes outside it (decoding, filtering and HEIF/JPEG encoding take
    /// tens of milliseconds and the lock also guards cancellation and other captures), then
    /// settles under the lock again. Continuations resume after the lock is released.
    private func finishCapture(photo: AVCapturePhoto, error: (any Error)?) {
        let id = photo.resolvedSettings.uniqueID

        let early: PhotoOutcome? = {
            lock.lock()
            defer { lock.unlock() }
            guard let pending = pendingCaptures[id] else { return .ignore }
            if pending.cancelled {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(PRMSessionError.cancelled))
            }
            if let error {
                pendingCaptures.removeValue(forKey: id)
                PRMLog.error(.capture, "Photo capture \(id) failed in AVFoundation", error: error)
                return .terminal(pending, .failure(Self.sessionError(for: error)))
            }
            return nil
        }()
        if let early {
            early.resume()
            return
        }
        guard let pending = peek(id) else { return }

        let originalData = Self.fileData(of: photo, manualISO: pending.manualISO, manualDuration: pending.manualExposureDuration)
        let result: PRMPhoto? = originalData.map { renderPhoto(originalData: $0, photo: photo, pending: pending) }

        let outcome: PhotoOutcome = {
            lock.lock()
            defer { lock.unlock() }
            // Cancelled (or settled elsewhere) while encoding.
            guard pendingCaptures[id] === pending else { return .ignore }
            if pending.cancelled {
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .failure(PRMSessionError.cancelled))
            }
            guard let result else {
                pendingCaptures.removeValue(forKey: id)
                PRMLog.error(
                    .capture,
                    "Photo capture \(id): fileDataRepresentation returned nil (\(Self.dimensionsText(of: photo)), manualEXIFPatch=\(pending.manualISO != nil))"
                )
                return .terminal(pending, .failure(PRMSessionError.photoCaptureFailed("No file data representation")))
            }
            switch pending.kind {
            case .single:
                pendingCaptures.removeValue(forKey: id)
                return .terminal(pending, .success(result))
            case .live:
                return finishLiveSuccess(id: id, pending: pending, result: result)
            }
        }()
        outcome.resume()
    }

    /// Live Photo success path. If the movie sidecar has already arrived (or errored),
    /// finalize now; otherwise stash the photo half on the pending entry and wait for the
    /// movie. Called with `lock` held.
    private func finishLiveSuccess(
        id: Int64,
        pending: PendingCapture,
        result: PRMPhoto
    ) -> PhotoOutcome {
        pending.capturedPhoto = result
        guard pending.liveMovieReady || pending.liveMovieError != nil else {
            return .pendingLiveMovie
        }
        pendingCaptures.removeValue(forKey: id)
        if let movieError = pending.liveMovieError {
            PRMLog.error(.capture, "Live Photo \(id): movie half failed", error: movieError)
            return .terminal(pending, .failure(Self.sessionError(for: movieError)))
        }
        return .terminal(pending, .success(result))
    }

    /// AVFoundation's error as a ``PRMSessionError``: ``PRMSessionError/captureFailed(_:)``
    /// keeps an `AVError`'s code (`-11872` when the hardware is out of resources, for
    /// example); anything else becomes ``PRMSessionError/photoCaptureFailed(_:)``.
    static func sessionError(for error: any Error) -> PRMSessionError {
        if let avError = error as? AVError {
            return .captureFailed(avError)
        }
        return .photoCaptureFailed(error.localizedDescription)
    }
}

// MARK: - PhotoOutcome

/// Resolution of a delegate callback against the pending-capture state machine. Computed under
/// the lock; resumed (via `resume()`) after the lock is released.
enum PhotoOutcome {
    /// No pending capture for this ID (e.g. a duplicate / stale callback) — drop on the floor.
    case ignore
    /// Waiting for the Live Photo movie sidecar to finish.
    case pendingLiveMovie
    /// Waiting for the Live Photo still to finish.
    case pendingPhoto
    /// Both halves have arrived (or one half failed) — resume the continuation.
    case terminal(PRMPhotoCapture.PendingCapture, Result<PRMPhoto, any Error>)

    func resume() {
        guard case let .terminal(pending, result) = self else { return }
        // Take-and-nil before resuming so any second arrival on this PendingCapture
        // silently no-ops: `CheckedContinuation.resume` crashes the process on a double
        // resume.
        switch pending.kind {
        case .single:
            guard let continuation = pending.singleContinuation else { return }
            pending.singleContinuation = nil
            PRMPhotoCapture.logOutcome(result, isLivePhoto: false)
            continuation.resume(with: result)
        case let .live(movieURL):
            if case .failure = result {
                // Ours to clean up: the caller never receives the URL. A no-op when the
                // movie was never written.
                PRMTempFile.remove(movieURL)
            }
            guard let continuation = pending.liveContinuation else { return }
            pending.liveContinuation = nil
            PRMPhotoCapture.logOutcome(result, isLivePhoto: true)
            continuation.resume(with: result.map { PRMLivePhoto(photo: $0, movieURL: movieURL) })
        }
    }
}
