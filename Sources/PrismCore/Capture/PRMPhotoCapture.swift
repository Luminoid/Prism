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
        let pending = PendingCapture(filter: filter, context: context, willCapture: willCapture)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                lock.lock()
                pendingCaptures[avSettings.uniqueID] = pending
                lock.unlock()
                output.capturePhoto(with: avSettings, delegate: self)
            }
        } onCancel: {
            // Mark as cancelled; the delegate callback completes the continuation.
            self.lock.lock()
            if let pending = self.pendingCaptures[avSettings.uniqueID] {
                pending.cancelled = true
            }
            self.lock.unlock()
        }
    }

    // MARK: - Pending tracker

    fileprivate final class PendingCapture {
        let filter: (any PRMFilter)?
        let context: PRMRenderContext?
        let willCapture: (@Sendable () -> Void)?
        var continuation: CheckedContinuation<PRMPhoto, Error>?
        var cancelled: Bool = false

        init(
            filter: (any PRMFilter)?,
            context: PRMRenderContext?,
            willCapture: (@Sendable () -> Void)?
        ) {
            self.filter = filter
            self.context = context
            self.willCapture = willCapture
        }
    }

    fileprivate func take(_ id: Int64) -> PendingCapture? {
        lock.lock()
        let pending = pendingCaptures.removeValue(forKey: id)
        lock.unlock()
        return pending
    }

    fileprivate func peek(_ id: Int64) -> PendingCapture? {
        lock.lock()
        let pending = pendingCaptures[id]
        lock.unlock()
        return pending
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
        guard let pending = take(id), let continuation = pending.continuation else { return }

        if pending.cancelled {
            continuation.resume(throwing: PRMSessionError.cancelled)
            return
        }
        if let error {
            continuation.resume(throwing: PRMSessionError.photoCaptureFailed(error.localizedDescription))
            return
        }
        guard let originalData = photo.fileDataRepresentation() else {
            continuation.resume(throwing: PRMSessionError.photoCaptureFailed("No file data representation"))
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
        continuation.resume(returning: result)
    }
}
