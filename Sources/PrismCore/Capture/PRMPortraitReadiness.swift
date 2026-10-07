@preconcurrency import AVFoundation
import CoreMedia
import QuartzCore

/// Whether a Portrait capture gets its depth effect right now, and what to tell the user when
/// it doesn't: the system Camera's yellow "NATURAL LIGHT" versus "Move farther away.",
/// "Place subject within 2.5 m." and "More light required."
///
/// ``PRMPortraitReadinessMonitor`` computes it from a live depth stream, the latest face and
/// body detections, and the camera's exposure. The pure helpers below are what it uses.
public enum PRMPortraitReadiness: Sendable, Equatable {
    /// The subject sits in the depth effect's range in enough light.
    case ready
    /// The subject is closer than the depth effect works.
    case moveFarther
    /// The subject is farther than the depth effect works.
    case moveCloser
    /// Too dark for a reliable depth effect.
    case needsMoreLight
    /// No usable depth reading yet.
    case searching
    /// No depth on this camera or in this configuration (Cinematic Video is on, or the active
    /// format streams no depth).
    case unavailable

    // MARK: - Thresholds

    /// The subject distances (meters) the depth effect works between.
    public struct Thresholds: Sendable, Equatable {
        public var minimumDistance: Float
        public var maximumDistance: Float

        public init(minimumDistance: Float = 0.5, maximumDistance: Float = 2.5) {
            self.minimumDistance = minimumDistance
            self.maximumDistance = maximumDistance
        }

        /// The defaults, with the near limit raised to 1.2× the lens's minimum focus distance
        /// (a telephoto lens focuses no closer than about a meter). `minimumFocusDistance` is
        /// `AVCaptureDevice.minimumFocusDistance` in millimeters; -1 (unknown) keeps 0.5 m.
        public static func forLens(minimumFocusDistance millimeters: Int) -> Self {
            let lensMinimum = millimeters > 0 ? Float(millimeters) / 1000 * 1.2 : 0
            return Self(minimumDistance: max(0.5, lensMinimum))
        }
    }

    // MARK: - Evaluation

    /// The readiness for a subject `distance` (meters, `nil` without a reading) in the given
    /// light. Low light wins over distance, as in the system Camera.
    public static func evaluate(distance: Float?, isLowLight: Bool, thresholds: Thresholds = Thresholds()) -> Self {
        if isLowLight { return .needsMoreLight }
        guard let distance, distance.isFinite, distance > 0 else { return .searching }
        if distance < thresholds.minimumDistance { return .moveFarther }
        if distance > thresholds.maximumDistance { return .moveCloser }
        return .ready
    }

    /// Whether auto exposure has run out of room: it can't reach its target by more than a
    /// stop (`exposureTargetOffset` below -1 EV), or ISO is at 85% of its maximum or more
    /// with the shutter at 1/20 s or longer.
    public static func isLowLight(iso: Float, maxISO: Float, exposureDuration: Double, targetOffset: Float) -> Bool {
        if targetOffset.isFinite, targetOffset < -1 { return true }
        return maxISO > 0 && iso >= 0.85 * maxISO && exposureDuration >= 1.0 / 20.0
    }

    // MARK: - Depth sampling

    /// The region to measure: the largest face or body among `detections`, shrunk to its
    /// middle half, or else a small square around `focusPoint`. Both are in device space
    /// (`0...1`, origin top-left of the unrotated sensor image), which the depth map shares.
    public static func subjectRegion(detections: [PRMDetectedObject], focusPoint: CGPoint) -> CGRect {
        let subjects = detections.filter(\.kind.isPortraitSubject)
        if let largest = subjects.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            let bounds = largest.bounds
            return bounds.insetBy(dx: bounds.width / 4, dy: bounds.height / 4)
        }
        let side: CGFloat = 0.2
        let x = min(max(focusPoint.x, 0), 1)
        let y = min(max(focusPoint.y, 0), 1)
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The median of the valid samples (finite and above zero) of a `DepthFloat32` map inside
    /// `region` (normalized, origin top-left), in meters. `nil` for another pixel format or a
    /// region without valid samples. Large regions are sampled on a grid of about 4,000
    /// points.
    public static func medianDepth(in region: CGRect, of depthMap: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let clipped = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard width > 0, height > 0, !clipped.isNull, !clipped.isEmpty else { return nil }
        let minX = min(width - 1, Int(clipped.minX * CGFloat(width)))
        let maxX = min(width, max(minX + 1, Int((clipped.maxX * CGFloat(width)).rounded(.up))))
        let minY = min(height - 1, Int(clipped.minY * CGFloat(height)))
        let maxY = min(height, max(minY + 1, Int((clipped.maxY * CGFloat(height)).rounded(.up))))
        let area = (maxX - minX) * (maxY - minY)
        let step = max(1, Int(Double(area / 4000).squareRoot().rounded(.up)))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var samples: [Float] = []
        samples.reserveCapacity(area / (step * step) + 1)
        for row in stride(from: minY, to: maxY, by: step) {
            let rowPointer = (base + row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for column in stride(from: minX, to: maxX, by: step) {
                let value = rowPointer[column]
                if value.isFinite, value > 0 {
                    samples.append(value)
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}

extension PRMDetectedObject.Kind {
    /// Faces, heads and bodies: what Portrait's depth effect keeps sharp.
    var isPortraitSubject: Bool {
        switch self {
        case .face, .humanBody, .humanFullBody, .catHead, .catBody, .dogHead, .dogBody: true
        case .focusTracked, .salientObject, .other: false
        }
    }
}

// MARK: - Debouncing

/// Holds a new readiness back until it repeats, so the indicator doesn't flicker between
/// states on one noisy depth sample. ``PRMPortraitReadiness/unavailable`` and the first value
/// pass at once.
struct PRMPortraitReadinessDebouncer {
    private(set) var current: PRMPortraitReadiness?
    private var candidate: PRMPortraitReadiness?
    private var candidateCount = 0
    let requiredRepeats: Int

    init(requiredRepeats: Int = 2) {
        self.requiredRepeats = max(1, requiredRepeats)
    }

    /// Feeds one sample; returns the readiness to report when it changes.
    mutating func feed(_ sample: PRMPortraitReadiness) -> PRMPortraitReadiness? {
        guard sample != current else {
            candidate = nil
            candidateCount = 0
            return nil
        }
        if current == nil || sample == .unavailable {
            return commit(sample)
        }
        if sample == candidate {
            candidateCount += 1
        } else {
            candidate = sample
            candidateCount = 1
        }
        return candidateCount >= requiredRepeats ? commit(sample) : nil
    }

    private mutating func commit(_ sample: PRMPortraitReadiness) -> PRMPortraitReadiness {
        current = sample
        candidate = nil
        candidateCount = 0
        return sample
    }
}

// MARK: - Monitor

/// Watches whether a Portrait capture would get its depth effect and streams
/// ``PRMPortraitReadiness`` changes for an on-screen indicator.
///
/// While running it owns the session's depth stream (`attachDepthDataOutput`), so call
/// ``PRMCamera/enableDepthFormat()`` first and don't attach another depth stream alongside.
/// It samples about six times a second: the median depth of the largest face or body (when
/// the metadata output detects them, see ``PRMCamera/setMetadataObjectTypes(_:)``) or of the
/// area around the focus point, against ``PRMPortraitReadiness/Thresholds/forLens(minimumFocusDistance:)``,
/// plus the camera's exposure for low light. A new state must repeat once before it's
/// reported. Cinematic Video excludes depth streams, so the monitor reports
/// ``PRMPortraitReadiness/unavailable`` while it's on.
///
/// ```swift
/// let monitor = PRMPortraitReadinessMonitor(session: camera.session)
/// try await monitor.start()
/// for await readiness in monitor.readinessStream() {
///     pill.show(readiness)
/// }
/// ```
public final class PRMPortraitReadinessMonitor: NSObject, @unchecked Sendable {
    // MARK: - Properties

    private let session: PRMCameraSession
    private let queue = DispatchQueue(label: "dev.luminoid.prism.portraitReadiness", qos: .userInitiated)
    private let states = PRMStreamRegistry<PRMPortraitReadiness>(bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock()
    private var _current: PRMPortraitReadiness = .searching
    private var device: AVCaptureDevice?
    private var detections: [PRMDetectedObject] = []
    private var detectionsTask: Task<Void, Never>?
    /// Only touched on `queue`.
    private var debouncer = PRMPortraitReadinessDebouncer()
    private var lastSampleTime: CFTimeInterval = 0
    private static let sampleInterval: CFTimeInterval = 1.0 / 6.0

    // MARK: - Init

    public init(session: PRMCameraSession) {
        self.session = session
        super.init()
    }

    deinit {
        detectionsTask?.cancel()
    }

    // MARK: - Public API

    /// The latest reported readiness.
    public var current: PRMPortraitReadiness {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    /// Readiness changes, starting with the current one.
    public func readinessStream() -> AsyncStream<PRMPortraitReadiness> {
        states.makeStream(initial: current)
    }

    /// Attaches the depth stream and starts sampling. Reports
    /// ``PRMPortraitReadiness/unavailable`` instead when Cinematic Video is on or the active
    /// format streams no depth. Calling it again re-reads the camera (after a switch).
    ///
    /// - Throws: ``PRMSessionError/cannotAttachToSession(_:)`` when the session can't add the
    ///   depth output.
    public func start() async throws {
        let (device, cinematic) = await (session.videoDevice, session.isCinematicVideoCaptureActive)
        guard let device, !cinematic, !device.activeFormat.supportedDepthDataFormats.isEmpty else {
            await session.detachDepthDataOutput()
            report(.unavailable, reason: cinematic ? "Cinematic Video is on" : "no depth format")
            return
        }
        lock.withLock { self.device = device }
        queue.async { [self] in
            debouncer = PRMPortraitReadinessDebouncer()
            lastSampleTime = 0
        }
        if detectionsTask == nil {
            let router = session.metadataRouter
            detectionsTask = Task { [weak self] in
                for await batch in router.detectedObjects() {
                    self?.setDetections(batch)
                }
            }
        }
        report(.searching, reason: "started")
        try await session.attachDepthDataOutput(delegate: self, queue: queue, filteringEnabled: true)
    }

    /// Detaches the depth stream and stops sampling.
    public func stop() async {
        detectionsTask?.cancel()
        detectionsTask = nil
        lock.withLock {
            device = nil
            detections = []
        }
        await session.detachDepthDataOutput()
        report(.searching, reason: "stopped")
    }

    // MARK: - Helpers

    private func setDetections(_ batch: [PRMDetectedObject]) {
        lock.lock()
        detections = batch
        lock.unlock()
    }

    /// Reports `readiness` directly (start, stop, unavailable), bypassing the debouncer.
    private func report(_ readiness: PRMPortraitReadiness, reason: String) {
        queue.async { [self] in
            _ = debouncer.feed(readiness)
        }
        publish(readiness, reason: reason)
    }

    private func publish(_ readiness: PRMPortraitReadiness, reason: String) {
        lock.lock()
        let changed = _current != readiness
        _current = readiness
        lock.unlock()
        guard changed else { return }
        PRMLog.debug(.capture, "Portrait readiness: \(String(describing: readiness)) (\(reason))")
        states.yield(readiness)
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate

extension PRMPortraitReadinessMonitor: AVCaptureDepthDataOutputDelegate {
    public func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= Self.sampleInterval else { return }
        lastSampleTime = now

        lock.lock()
        let device = device
        let detections = detections
        lock.unlock()
        guard let device else { return }

        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        var region = PRMPortraitReadiness.subjectRegion(detections: detections, focusPoint: device.focusPointOfInterest)
        if connection.isVideoMirrored {
            region.origin.x = 1 - region.maxX
        }
        let distance = PRMPortraitReadiness.medianDepth(in: region, of: depth.depthDataMap)
        let isLowLight = PRMPortraitReadiness.isLowLight(
            iso: device.iso,
            maxISO: device.activeFormat.maxISO,
            exposureDuration: CMTimeGetSeconds(device.exposureDuration),
            targetOffset: device.exposureTargetOffset
        )
        let lens = device.activePrimaryConstituent ?? device
        let sample = PRMPortraitReadiness.evaluate(
            distance: distance,
            isLowLight: isLowLight,
            thresholds: .forLens(minimumFocusDistance: lens.minimumFocusDistance)
        )
        if let changed = debouncer.feed(sample) {
            let meters = distance.map { String(format: "%.2f m", $0) } ?? "no reading"
            publish(changed, reason: meters)
        }
    }
}
