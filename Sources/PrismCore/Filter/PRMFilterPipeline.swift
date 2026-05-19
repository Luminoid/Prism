import AVFoundation
import CoreMedia

/// Routes video frames from `AVCaptureVideoDataOutput` through an active ``PRMFilterRenderer``.
///
/// Pipeline acts as the `AVCaptureVideoDataOutputSampleBufferDelegate`. Frames are dispatched
/// via two channels — pick whichever fits your code:
/// - A simple `onFrame` callback (synchronous from the data-output queue).
/// - An `AsyncStream<PRMVideoFrame>` for structured concurrency consumers.
///
/// ```swift
/// let pipeline = PRMFilterPipeline()
/// pipeline.activeRenderer = sepiaRenderer
/// pipeline.isEnabled = true
/// camera.session.setVideoDataOutputDelegate(pipeline)
///
/// // Option A: callback
/// pipeline.onFrame = { frame in
///     previewView.pixelBuffer = frame.pixelBuffer
/// }
///
/// // Option B: AsyncStream
/// Task {
///     for await frame in pipeline.frameStream() {
///         await previewView.updateBuffer(frame.pixelBuffer)
///     }
/// }
/// ```
public final class PRMFilterPipeline: NSObject, @unchecked Sendable {
    // MARK: - Public state

    /// The currently active renderer. Setting `nil` makes the pipeline pass through raw frames.
    public var activeRenderer: (any PRMFilterRenderer)? {
        didSet {
            if oldValue !== activeRenderer { oldValue?.reset() }
        }
    }

    /// Enable/disable frame processing. Set to `false` during session reconfiguration.
    public var isEnabled: Bool = false

    /// Callback delivery (legacy / sync consumers). Called on the data-output queue.
    public var onFrame: ((PRMVideoFrame) -> Void)?

    /// Most recent frame's format description.
    public private(set) var currentFormatDescription: CMFormatDescription?

    // MARK: - Streams

    private var streamContinuations: [UUID: AsyncStream<PRMVideoFrame>.Continuation] = [:]
    private let streamLock = NSLock()

    /// Async stream of processed frames.
    public func frameStream() -> AsyncStream<PRMVideoFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            streamLock.lock()
            streamContinuations[id] = continuation
            streamLock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                streamLock.lock()
                streamContinuations.removeValue(forKey: id)
                streamLock.unlock()
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PRMFilterPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled else { return }
        guard let videoBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        currentFormatDescription = formatDescription
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var processedBuffer = videoBuffer
        if let renderer = activeRenderer {
            if !renderer.isPrepared {
                renderer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
            }
            if let filtered = renderer.render(pixelBuffer: videoBuffer) {
                processedBuffer = filtered
            }
        }

        let frame = PRMVideoFrame(
            pixelBuffer: processedBuffer,
            timestamp: timestamp,
            formatDescription: formatDescription
        )
        onFrame?(frame)

        streamLock.lock()
        let continuations = Array(streamContinuations.values)
        streamLock.unlock()
        for continuation in continuations {
            continuation.yield(frame)
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        PRMLogger.filter.debug("Dropped video frame")
    }
}
