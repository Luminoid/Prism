import AVFoundation
import CoreImage
import os

/// Handles still photo capture as an `AVCapturePhotoCaptureDelegate`.
///
/// Unlike AnimalVision's `PhotoCaptureProcessor`, this does **not** save to the photo library.
/// Instead, it delivers the captured photo data to the consumer via callbacks.
///
/// ```swift
/// let processor = PRMPhotoCaptureProcessor(settings: photoSettings) { photo in
///     // Apply filter to captured photo
///     guard let data = photo.fileDataRepresentation() else { return nil }
///     return data
/// }
/// photoOutput.capturePhoto(with: photoSettings, delegate: processor)
/// ```
public final class PRMPhotoCaptureProcessor: NSObject, @unchecked Sendable {
    // MARK: - Properties

    /// The photo settings used for this capture.
    public let photoSettings: AVCapturePhotoSettings

    /// Processes the captured photo and returns optional filtered data.
    /// Called on a background queue.
    public var photoProcessingHandler: ((AVCapturePhoto) -> Data?)?

    /// Called when the shutter fires — use for shutter animation.
    public var willCapturePhotoHandler: (() -> Void)?

    /// Called when capture is fully complete (success or failure).
    public var completionHandler: ((PRMPhotoCaptureProcessor) -> Void)?

    /// Called when the photo processing begins (for long-exposure feedback).
    public var processingStartedHandler: ((Bool) -> Void)?

    /// The final captured photo data, or `nil` if capture failed.
    public private(set) var capturedPhotoData: Data?

    private var maxPhotoProcessingTime: CMTime?

    // MARK: - Initialization

    /// Creates a photo capture processor.
    ///
    /// - Parameters:
    ///   - settings: The `AVCapturePhotoSettings` for this capture.
    ///   - photoProcessingHandler: Closure to process the captured photo. Return `Data` to store, or `nil`.
    public init(
        settings: AVCapturePhotoSettings,
        photoProcessingHandler: ((AVCapturePhoto) -> Data?)? = nil,
    ) {
        self.photoSettings = settings
        self.photoProcessingHandler = photoProcessingHandler
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PRMPhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
    ) {
        #if !os(macOS)
            maxPhotoProcessingTime = resolvedSettings.photoProcessingTimeRange.start
                + resolvedSettings.photoProcessingTimeRange.duration
        #endif
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
    ) {
        willCapturePhotoHandler?()

        // Notify if processing will take noticeable time
        if let maxTime = maxPhotoProcessingTime {
            let isProcessing = maxTime > CMTime(seconds: 1, preferredTimescale: 1)
            processingStartedHandler?(isProcessing)
        }
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?,
    ) {
        if let error {
            PRMLogger.capture.error("Photo processing error: \(error.localizedDescription)")
            return
        }

        if let handler = photoProcessingHandler {
            capturedPhotoData = handler(photo)
        } else {
            capturedPhotoData = photo.fileDataRepresentation()
        }
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?,
    ) {
        if let error {
            PRMLogger.capture.error("Photo capture error: \(error.localizedDescription)")
        }
        completionHandler?(self)
    }
}
