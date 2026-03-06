import AVFoundation
import CoreMedia
import os

/// Manages the active filter renderer and routes video sample buffers through it.
///
/// `PRMFilterPipeline` acts as the `AVCaptureVideoDataOutputSampleBufferDelegate`,
/// receiving frames from the camera and passing them through the current renderer.
///
/// ```swift
/// let pipeline = PRMFilterPipeline()
/// pipeline.activeRenderer = grayscaleRenderer
/// pipeline.isRenderingEnabled = true
/// // Assign pipeline as the delegate of your AVCaptureVideoDataOutput
/// ```
public final class PRMFilterPipeline: NSObject, @unchecked Sendable {
    // MARK: - Properties

    /// The currently active filter renderer. Set to `nil` to disable filtering (pass-through).
    ///
    /// When changing renderers, the previous renderer is automatically reset.
    public var activeRenderer: (any PRMCameraFilterRenderer)? {
        didSet {
            oldValue?.reset()
        }
    }

    /// Controls whether video frames are processed. Set to `false` during session reconfiguration.
    public var isRenderingEnabled = false

    /// Called on the data output queue with each processed (or pass-through) pixel buffer.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The video frame (filtered if a renderer is active, raw otherwise).
    ///   - timestamp: The presentation timestamp of the frame.
    public var onFrame: ((_ pixelBuffer: CVPixelBuffer, _ timestamp: CMTime) -> Void)?

    // MARK: - State

    /// The most recently processed frame's format description.
    public private(set) var currentFormatDescription: CMFormatDescription?
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PRMFilterPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection,
    ) {
        guard isRenderingEnabled else { return }

        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        currentFormatDescription = formatDescription
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var finalPixelBuffer = videoPixelBuffer

        if let renderer = activeRenderer {
            if !renderer.isPrepared {
                renderer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
            }

            if let filteredBuffer = renderer.render(pixelBuffer: videoPixelBuffer) {
                finalPixelBuffer = filteredBuffer
            } else {
                PRMLogger.filter.debug("Filter render returned nil, using raw frame")
            }
        }

        onFrame?(finalPixelBuffer, timestamp)
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection,
    ) {
        PRMLogger.filter.debug("Dropped video frame")
    }
}
