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
/// await camera.session.setVideoDataOutputDelegate(pipeline)
///
/// // Option A: callback (runs on the data-output queue; `update(_:)` is thread-safe)
/// pipeline.onFrame = { [weak previewView] frame in
///     previewView?.update(frame.pixelBuffer)
/// }
///
/// // Option B: AsyncStream
/// Task {
///     for await frame in pipeline.frameStream() {
///         previewView.update(frame.pixelBuffer)
///     }
/// }
/// ```
public final class PRMFilterPipeline: NSObject, @unchecked Sendable {
    // MARK: - Public state

    /// The currently active renderer. Setting `nil` makes the pipeline pass through raw frames.
    ///
    /// The renderer it replaces is reset on the data-output queue when the next frame
    /// arrives, not here: the queue may be inside that renderer's `render` right now, and a
    /// reset from this thread could race it (or be undone by a re-prepare a moment later).
    public var activeRenderer: (any PRMFilterRenderer)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _activeRenderer
        }
        set {
            stateLock.lock()
            _activeRenderer = newValue
            stateLock.unlock()
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

    /// Format description of the most recent frame (dimensions, pixel format, color
    /// extensions), or `nil` before the first one.
    public var currentFormatDescription: CMFormatDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentFormatDescription
    }

    // MARK: - Private storage

    private var _activeRenderer: (any PRMFilterRenderer)?
    /// The renderer the previous frame used. Only touched on the data-output queue.
    private var lastFrameRenderer: (any PRMFilterRenderer)?
    private var _isEnabled: Bool = false
    private var _onFrame: ((PRMVideoFrame) -> Void)?
    private var _currentFormatDescription: CMFormatDescription?
    private let stateLock = NSLock()

    // MARK: - Frame stream

    /// Drops older queued frames so only the newest pending frame survives — correct for
    /// preview consumers that prefer "skip the stale frame" over "play yesterday's frame".
    /// See ``frameStream`` doc for the backpressure rationale.
    private let frames = PRMStreamRegistry<PRMVideoFrame>(bufferingPolicy: .bufferingNewest(1))

    // Dropped-frame rollup state. AVFoundation calls `captureOutput(_:didDrop:from:)`
    // for every dropped frame — at 30-60 fps under interruption (incoming call,
    // control-center pull, multi-app camera arbitration, slow consumer) this floods
    // the log with hundreds of identical "Dropped video frame" lines, drowning
    // signal. Counting here and flushing the count every `dropLogInterval` seconds
    // turns a torrent into a single rolled-up line ("Dropped N frames in last X.Xs").
    private var droppedFrameCount: UInt64 = 0
    private var lastDropLogTime: CFTimeInterval = 0
    private let dropLogInterval: CFTimeInterval = 2.0

    // Capture-to-delivery latency rollup over `latencyLogInterval` seconds, logged at debug
    // when the window was slow: how far behind the sensor each frame reaches the consumer
    // (stabilization and effects such as Cinematic Video add to it). Only touched on the
    // data-output queue.
    private var latencyWindow = LatencyWindow()
    private let latencyLogInterval: CFTimeInterval = 5.0

    /// Async stream of processed frames.
    ///
    /// **Drops frames under backpressure.** Buffering policy is `.bufferingNewest(1)`:
    /// when the consumer is slower than the camera (30–60 fps), older queued frames are
    /// silently discarded so only the newest pending frame survives. This is the right
    /// trade-off for *preview* consumers (showing yesterday's frame is worse than
    /// skipping it), but it is **wrong** for consumers that must see every frame —
    /// recording, ML inference batching, motion-vector estimation. Those should consume
    /// via the synchronous ``onFrame`` callback instead, where the consumer runs on the
    /// data-output queue and naturally backpressures by holding the queue. Frames the
    /// capture output drops are counted and logged as one notice line every 2 seconds
    /// (subsystem `dev.luminoid.prism`, category `Filter`).
    public func frameStream() -> AsyncStream<PRMVideoFrame> {
        frames.makeStream()
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
        stateLock.unlock()

        // A renderer swapped out since the last frame is released here, on this queue,
        // where no render of it can be running.
        if let previous = lastFrameRenderer, previous !== renderer {
            previous.reset()
        }
        lastFrameRenderer = renderer

        guard enabled else { return }
        guard let videoBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Detect mid-session format changes triggered by any of:
        //   - `device.activeFormat` swap (Max Dimensions toggle: 12MP → 48MP)
        //   - pixel-format change (auto-AE re-coupling to a depth-streaming format
        //     after entering manual exposure can flip the videoDataOutput's
        //     connection between BGRA and YUV variants even though
        //     `videoDataOutput.videoSettings` keeps the requested format stable
        //     — AVFoundation routes through a transitional buffer during
        //     reconfiguration that doesn't honor the override)
        //   - color-space / extension change (HDR off→on, color primaries swap)
        //
        // Without this, the prepared renderer's `outputPixelBufferPool` stays
        // sized + formatted to the OLD format. New frames either fail to render
        // or produce visually wrong output:
        //   - **two stacked previews vertically**: pool sized to old WxH but new
        //     frame is W'xH' (different dimensions) → renderer overflows and the
        //     GPU samples beyond the texture bounds.
        //   - **two stacked previews horizontally** + **weird color**: pool sized
        //     correctly but the source CVPixelBuffer is now YUV biplanar where
        //     the renderer / Metal texture cache reads it as single-plane BGRA →
        //     the two Y/UV planes get sampled side-by-side as if they were one
        //     contiguous BGRA texture. This is the post-Max-Dimensions-off →
        //     custom-exposure failure mode on iPhone 15 Pro Max wide.
        //
        // Comparing the full `CMFormatDescription` (dimensions + media subtype +
        // extension keys via `CMFormatDescriptionEqual`) catches all three cases.
        let previousFormatDescription: CMFormatDescription?
        stateLock.lock()
        previousFormatDescription = _currentFormatDescription
        _currentFormatDescription = formatDescription
        stateLock.unlock()

        let formatChanged: Bool = {
            guard let previousFormatDescription else { return false }
            // `CMFormatDescriptionEqual` compares media type + subtype +
            // dimensions + every extension key (color primaries, transfer
            // function, YCbCr matrix, etc.). Returns true if equal — we want
            // the inverse for the change signal.
            return !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: previousFormatDescription)
        }()

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var processedBuffer = videoBuffer
        if let renderer {
            if !renderer.isPrepared || formatChanged {
                if formatChanged {
                    // Tear down the old pool before re-preparing — keeping it would
                    // leak the prior format's buffers across the swap.
                    renderer.reset()
                    let newDims = CMVideoFormatDescriptionGetDimensions(formatDescription)
                    let newSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
                    PRMLog.notice(
                        .filter,
                        "Reconfiguring renderer for new format (dims=\(newDims.width)×\(newDims.height), subType=\(PRMLog.fourCC(newSubType)))"
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
        frames.yield(frame)
        recordLatency(of: timestamp)
    }

    /// Adds this frame's presentation-to-now latency to the rollup and logs a slow window
    /// (see ``LatencyWindow/Summary/isSlow``) when it closes. Presentation times are on the
    /// session's clock, the host clock on iOS; a value outside 0...10 s means another clock
    /// and is skipped.
    private func recordLatency(of timestamp: CMTime) {
        guard timestamp.isNumeric else { return }
        let latency = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), timestamp))
        guard latency >= 0, latency < 10 else { return }
        let now = CACurrentMediaTime()
        guard let summary = latencyWindow.add(latency, now: now, interval: latencyLogInterval), summary.isSlow else { return }
        PRMLog.debug(
            .filter,
            "Slow frame latency over \(String(format: "%.1f", summary.span))s: avg \(Int(summary.average * 1000)) ms, max \(Int(summary.maximum * 1000)) ms (\(summary.count) frames)"
        )
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
            PRMLog.notice(.filter, "Dropped \(countToFlush) video frame(s) in last \(String(format: "%.2f", intervalToFlush))s")
        }
    }
}

// MARK: - Latency window

/// Average and maximum of the latencies added since the last flush.
struct LatencyWindow {
    struct Summary: Equatable {
        let average: Double
        let maximum: Double
        let count: Int
        let span: CFTimeInterval

        /// Whether the window lagged enough to log: an average of 100 ms or more (about three
        /// frames at 30 fps; a healthy preview runs one to two), or a single frame 250 ms or
        /// more behind (a visible stall).
        var isSlow: Bool {
            average >= 0.1 || maximum >= 0.25
        }
    }

    private var sum: Double = 0
    private var maximum: Double = 0
    private var count = 0
    private var start: CFTimeInterval?
    private var last: CFTimeInterval?

    /// Adds `latency`; returns the window's summary and starts a new one once `interval`
    /// seconds have passed since its first sample. A gap longer than `interval` (the session
    /// stopped, or the app was in the background) drops the samples before it, so a summary
    /// never spans one.
    mutating func add(_ latency: Double, now: CFTimeInterval, interval: CFTimeInterval) -> Summary? {
        if let last, now - last > interval {
            self = Self()
        }
        last = now
        let windowStart = start ?? now
        start = windowStart
        sum += latency
        maximum = max(maximum, latency)
        count += 1
        guard now - windowStart >= interval else { return nil }
        let summary = Summary(average: sum / Double(count), maximum: maximum, count: count, span: now - windowStart)
        self = Self()
        return summary
    }
}
