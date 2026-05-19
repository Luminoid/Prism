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
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _activeRenderer
        }
        set {
            stateLock.lock()
            let old = _activeRenderer
            _activeRenderer = newValue
            stateLock.unlock()
            if old !== newValue { old?.reset() }
        }
    }

    /// Enable/disable frame processing. Set to `false` during session reconfiguration.
    public var isEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isEnabled
        }
        set {
            stateLock.lock()
            _isEnabled = newValue
            stateLock.unlock()
        }
    }

    /// Callback delivery (legacy / sync consumers). Called on the data-output queue.
    public var onFrame: ((PRMVideoFrame) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onFrame
        }
        set {
            stateLock.lock()
            _onFrame = newValue
            stateLock.unlock()
        }
    }

    /// Most recent frame's format description.
    public var currentFormatDescription: CMFormatDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentFormatDescription
    }

    // MARK: - Private storage

    private var _activeRenderer: (any PRMFilterRenderer)?
    private var _isEnabled: Bool = false
    private var _onFrame: ((PRMVideoFrame) -> Void)?
    private var _currentFormatDescription: CMFormatDescription?
    private let stateLock = NSLock()

    // MARK: - Streams

    private var streamContinuations: [UUID: AsyncStream<PRMVideoFrame>.Continuation] = [:]

    deinit {
        // Don't leave consumers hanging on `for await frame in pipeline.frameStream()` if the
        // pipeline is deallocated mid-iteration.
        stateLock.lock()
        let continuations = Array(streamContinuations.values)
        streamContinuations.removeAll()
        stateLock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Async stream of processed frames.
    public func frameStream() -> AsyncStream<PRMVideoFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            stateLock.lock()
            streamContinuations[id] = continuation
            stateLock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                stateLock.lock()
                streamContinuations.removeValue(forKey: id)
                stateLock.unlock()
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
        // Snapshot all shared state under one lock so frame delivery sees a consistent view —
        // and so a concurrent `activeRenderer = nil` can't reset() the renderer while we're
        // mid-render here on the data-output queue.
        stateLock.lock()
        let enabled = _isEnabled
        let renderer = _activeRenderer
        let onFrameCallback = _onFrame
        let continuations = Array(streamContinuations.values)
        stateLock.unlock()

        guard enabled else { return }
        guard let videoBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        stateLock.lock()
        _currentFormatDescription = formatDescription
        stateLock.unlock()

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var processedBuffer = videoBuffer
        if let renderer {
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
        onFrameCallback?(frame)
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
