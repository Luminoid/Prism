import AVFoundation
import CoreMedia
import QuartzCore

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

    // Dropped-frame rollup state. AVFoundation calls `captureOutput(_:didDrop:from:)`
    // for every dropped frame — at 30-60 fps under interruption (incoming call,
    // control-center pull, multi-app camera arbitration, slow consumer) this floods
    // the log with hundreds of identical "Dropped video frame" lines, drowning
    // signal. Counting here and flushing the count every `dropLogInterval` seconds
    // turns a torrent into a single rolled-up line ("Dropped N frames in last X.Xs").
    private var droppedFrameCount: UInt64 = 0
    private var lastDropLogTime: CFTimeInterval = 0
    private let dropLogInterval: CFTimeInterval = 2.0

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
    ///
    /// **Drops frames under backpressure.** Buffering policy is `.bufferingNewest(1)`:
    /// when the consumer is slower than the camera (30–60 fps), older queued frames are
    /// silently discarded so only the newest pending frame survives. This is the right
    /// trade-off for *preview* consumers (showing yesterday's frame is worse than
    /// skipping it), but it is **wrong** for consumers that must see every frame —
    /// recording, ML inference batching, motion-vector estimation. Those should consume
    /// via the synchronous ``onFrame`` callback instead, where the consumer runs on the
    /// data-output queue and naturally backpressures by holding the queue. Dropped
    /// frames are also logged via the dedicated `didDrop` delegate path (visible at
    /// `.debug` level under `com.luminoid.Prism.Filter`).
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

        // Detect mid-session format changes (e.g. `device.activeFormat` swap when
        // toggling Max Dimensions — 12MP → 48MP changes the connection dimensions
        // even though `videoDataOutput.videoSettings` keeps the pixel format
        // stable). Without this, the prepared renderer's `outputPixelBufferPool`
        // stays sized to the OLD format, and new frames either fail to render or
        // produce visually wrong output: classic symptoms are "two preview frames
        // stacked vertically" (the renderer overflowing into a wrong-sized pool
        // and the GPU sampling beyond the texture bounds) and "weird colors" (the
        // BGRA pool sized for HxW now receives W'xH' bytes and the sampler reads
        // misaligned pixels). Comparing format dimensions catches the swap; we
        // also compare the previous format description to catch color-space /
        // FOV changes that don't change pixel dimensions.
        let previousFormatDescription: CMFormatDescription?
        stateLock.lock()
        previousFormatDescription = _currentFormatDescription
        _currentFormatDescription = formatDescription
        stateLock.unlock()

        let formatChanged: Bool = {
            guard let previousFormatDescription else { return false }
            let newDims = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let oldDims = CMVideoFormatDescriptionGetDimensions(previousFormatDescription)
            return newDims.width != oldDims.width || newDims.height != oldDims.height
        }()

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var processedBuffer = videoBuffer
        if let renderer {
            if !renderer.isPrepared || formatChanged {
                if formatChanged {
                    // Tear down the old pool before re-preparing — keeping it would
                    // leak the prior format's buffers across the swap.
                    renderer.reset()
                    PRMLogger.filter.notice(
                        "Reconfiguring renderer for new format (dimensions changed across session)"
                    )
                }
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
        stateLock.lock()
        droppedFrameCount &+= 1
        let now = CACurrentMediaTime()
        if lastDropLogTime == 0 {
            lastDropLogTime = now
        }
        let elapsed = now - lastDropLogTime
        let shouldFlush = elapsed >= dropLogInterval
        let countToFlush: UInt64
        let intervalToFlush: CFTimeInterval
        if shouldFlush {
            countToFlush = droppedFrameCount
            intervalToFlush = elapsed
            droppedFrameCount = 0
            lastDropLogTime = now
        } else {
            countToFlush = 0
            intervalToFlush = 0
        }
        stateLock.unlock()

        if shouldFlush, countToFlush > 0 {
            // Promoted from `.debug` to `.notice` so consumers can see catastrophic
            // drop rates (interruption, slow ML pipeline starving the queue) without
            // turning on debug logging. Rolled up to one line per `dropLogInterval`s
            // — the previous per-frame `.debug` line flooded the log at 30-60 lines/s
            // under interruption with no useful aggregate signal.
            PRMLogger.filter.notice(
                "Dropped \(countToFlush, privacy: .public) video frame(s) in last \(intervalToFlush, format: .fixed(precision: 2), privacy: .public)s"
            )
        }
    }
}
