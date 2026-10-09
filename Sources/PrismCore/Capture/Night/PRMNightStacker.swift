import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import simd

/// Takes frames from the video-data stream, checks they carry the planned exposure, and
/// aligns and merges them on its own serial queue.
///
/// ``offer(_:)`` runs on the data-output queue and returns at once: a frame that arrives
/// while the previous one is still merging is skipped, so at most one capture buffer is held
/// at a time. The first accepted frame is the reference; later frames are rejected when much
/// blurrier than the frames so far (hand shake; see ``SharpnessGate``) or when they can't be
/// aligned.
final class PRMNightStacker: @unchecked Sendable {
    struct Status: Equatable {
        var merged = 0
        /// Too blurred, or not alignable.
        var rejected = 0
        /// At the planned exposure but arrived while the previous frame was still merging.
        var skipped = 0
        var lastAcceptedTime: CFTimeInterval?
        var timing = Timing()
    }

    /// Where the stacker's time goes for each frame it processed (merged or rejected):
    /// preparing it (BGRA, the quarter-size copy, sharpness), aligning it (Vision and the
    /// identity check) and the GPU merge. Frames that take longer than the frame interval are
    /// why later ones arrive while it's busy (``Status/skipped``).
    struct Timing: Equatable {
        private(set) var frames = 0
        private(set) var prepare: CFTimeInterval = 0
        private(set) var align: CFTimeInterval = 0
        private(set) var merge: CFTimeInterval = 0

        /// Adds one frame from the times its stages ended. A stage the frame never reached
        /// (rejected before it) counts as zero.
        mutating func add(start: CFTimeInterval, prepared: CFTimeInterval?, aligned: CFTimeInterval?, end: CFTimeInterval) {
            frames += 1
            prepare += (prepared ?? end) - start
            guard let prepared else { return }
            align += (aligned ?? end) - prepared
            guard let aligned else { return }
            merge += end - aligned
        }

        /// "95 ms a frame: 9 prepare, 58 align, 28 merge", or empty before the first frame.
        var summary: String {
            guard frames > 0 else { return "" }
            func milliseconds(_ seconds: CFTimeInterval) -> Int {
                Int((seconds / Double(frames) * 1000).rounded())
            }
            return "\(milliseconds(prepare + align + merge)) ms a frame: \(milliseconds(prepare)) prepare, \(milliseconds(align)) align, \(milliseconds(merge)) merge"
        }
    }

    /// What ``offer(_:)`` does with a frame.
    enum Intake: Equatable {
        case merge
        /// A frame the plan wanted, dropped because the previous one is still merging.
        case skip
        /// Not wanted: the capture is over, the plan is full, or the exposure isn't the
        /// planned one yet.
        case ignore
    }

    static func intake(isAccepting: Bool, isBusy: Bool, merged: Int, planned: Int, atPlannedExposure: Bool) -> Intake {
        guard isAccepting, merged < planned, atPlannedExposure else { return .ignore }
        return isBusy ? .skip : .merge
    }

    private let plan: PRMNightPlan
    private let context: PRMRenderContext
    private let ghost: (low: Float, high: Float)
    private let queue = DispatchQueue(label: "dev.luminoid.prism.night", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var status = Status()
    private var isBusy = false
    private var isAccepting = true
    private var settleDeadline: CFTimeInterval = .infinity
    private var loggedFrameFormat = false
    // Only touched on `queue`.
    private var merger: PRMNightMerger?
    private var registration: PRMNightRegistration?
    private var referenceSmall: CVPixelBuffer?
    private var sharpnessGate = SharpnessGate()
    private var referenceAttachments: [String: Any]?
    private var conversionBuffer: CVPixelBuffer?

    init(plan: PRMNightPlan, context: PRMRenderContext) {
        self.plan = plan
        self.context = context
        ghost = PRMNightRegistration.ghostThresholds(iso: plan.iso)
    }

    var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Frames without exposure metadata count once this time has passed (the exposure was
    /// confirmed shortly before).
    func setSettleDeadline(_ time: CFTimeInterval) {
        lock.lock()
        settleDeadline = time
        lock.unlock()
    }

    func stopAccepting() {
        lock.lock()
        isAccepting = false
        lock.unlock()
    }

    /// Waits until the frame being merged (if any) is done.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Intake (data-output queue)

    func offer(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [String: Any]
        let matches = Self.exposureMatches(attachments, plan: plan)
        let now = CACurrentMediaTime()

        lock.lock()
        let intake = Self.intake(
            isAccepting: isAccepting,
            isBusy: isBusy,
            merged: status.merged,
            planned: plan.frameCount,
            atPlannedExposure: matches ?? (now >= settleDeadline)
        )
        let accept = intake == .merge
        if accept {
            isBusy = true
            status.lastAcceptedTime = now
        } else if intake == .skip {
            status.skipped += 1
        }
        let logFormat = !loggedFrameFormat
        loggedFrameFormat = true
        lock.unlock()

        if logFormat, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let exif = attachments?[kCGImagePropertyExifDictionary as String] as? [String: Any]
            PRMLog.notice(
                .capture,
                "Night: frames \(dimensions.width)×\(dimensions.height) \(PRMLog.fourCC(CMFormatDescriptionGetMediaSubType(description))), exposure metadata \(exif == nil ? "missing" : "present")"
            )
        }
        guard accept, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if accept {
                lock.lock()
                isBusy = false
                lock.unlock()
            }
            return
        }
        // Handed to one queue and used only there.
        nonisolated(unsafe) let work = (pixelBuffer, attachments)
        queue.async { [self] in
            process(work.0, attachments: work.1)
            lock.lock()
            isBusy = false
            lock.unlock()
        }
    }

    /// Whether a frame's `{Exif}` exposure matches the plan (shutter within 15 %, ISO within
    /// 20 %), or `nil` when the frame carries no exposure metadata.
    static func exposureMatches(_ attachments: [String: Any]?, plan: PRMNightPlan) -> Bool? {
        guard let exif = attachments?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let shutter = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
              shutter > 0
        else { return nil }
        guard abs(shutter - plan.frameDuration) / plan.frameDuration <= 0.15 else { return false }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue, plan.iso > 0 {
            return abs(iso - Double(plan.iso)) / Double(plan.iso) <= 0.2
        }
        return true
    }

    // MARK: - Merging (stacker queue)

    private func process(_ frame: CVPixelBuffer, attachments: [String: Any]?) {
        let start = CACurrentMediaTime()
        var prepared: CFTimeInterval?
        var aligned: CFTimeInterval?
        defer {
            let end = CACurrentMediaTime()
            lock.lock()
            status.timing.add(start: start, prepared: prepared, aligned: aligned, end: end)
            lock.unlock()
        }
        guard let bgra = bgraFrame(frame) else { return reject("not convertible to BGRA") }
        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        if merger == nil {
            registration = PRMNightRegistration(fullWidth: width, fullHeight: height, context: context.ciContext)
            merger = PRMNightMerger(device: context.device, commandQueue: context.commandQueue, width: width, height: height)
        }
        guard let merger, let registration, merger.width == width, merger.height == height else {
            return reject("size changed or merge unavailable")
        }
        guard let small = registration.makeSmall(bgra) else { return reject("downscale failed") }
        let sharpness = PRMNightRegistration.sharpness(small)
        let typicalSharpness = sharpnessGate.typical
        let isSharpEnough = sharpnessGate.admits(sharpness)
        prepared = CACurrentMediaTime()

        guard let referenceSmall else {
            aligned = prepared
            guard merger.add(frame: bgra, frameSmall: small, referenceSmall: small, warp: matrix_identity_float3x3, isReference: true, ghost: ghost) else {
                return reject("GPU merge failed")
            }
            self.referenceSmall = small
            referenceAttachments = attachments
            merged()
            return
        }
        guard isSharpEnough else {
            return reject("blurred (sharpness \(Int(sharpness)) vs typical \(Int(typicalSharpness ?? 0)))")
        }
        guard let warp = registration.warp(floatingSmall: small, referenceSmall: referenceSmall) else {
            return reject("couldn't align")
        }
        aligned = CACurrentMediaTime()
        guard merger.add(frame: bgra, frameSmall: small, referenceSmall: referenceSmall, warp: warp, isReference: false, ghost: ghost) else {
            return reject("GPU merge failed")
        }
        merged()
    }

    /// `frame` itself when it's BGRA; otherwise a BGRA copy (Core Image converts YUV).
    private func bgraFrame(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(frame) != kCVPixelFormatType_32BGRA else { return frame }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        if conversionBuffer.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) ?? true {
            conversionBuffer = PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        }
        guard let conversionBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        context.ciContext.render(image, to: conversionBuffer, bounds: image.extent, colorSpace: colorSpace)
        CVBufferSetAttachment(conversionBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return conversionBuffer
    }

    private func merged() {
        lock.lock()
        status.merged += 1
        lock.unlock()
    }

    private func reject(_ reason: String) {
        lock.lock()
        status.rejected += 1
        let count = status.rejected
        lock.unlock()
        PRMLog.debug(.capture, "Night: frame \(count) rejected: \(reason)")
    }

    // MARK: - Sharpness

    /// Rejects frames much blurrier than the burst so far: under half the median sharpness of
    /// the frames seen before (accepted or not).
    ///
    /// The median rather than the reference frame: on a flat scene the metric sits near its
    /// noise floor, and one frame that measured sharper than the rest (sharpness 10 against 4
    /// to 5 on a device run) made every later frame look blurred, leaving 3 of 17 merged.
    struct SharpnessGate {
        private(set) var seen: [Float] = []

        /// The median of the frames seen so far, `nil` before the first.
        var typical: Float? {
            guard !seen.isEmpty else { return nil }
            let sorted = seen.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }

        /// Records `sharpness` and returns whether the frame is sharp enough to merge. The
        /// first frame always is.
        mutating func admits(_ sharpness: Float) -> Bool {
            defer { seen.append(sharpness) }
            guard let typical, typical > 0 else { return true }
            return sharpness >= 0.5 * typical
        }
    }

    // MARK: - Result

    /// The normalized linear merge (`64RGBAHalf`) and the reference frame's attachments, once
    /// ``drain()`` returned. `nil` when no frame was merged.
    func finish() -> (image: CVPixelBuffer, attachments: [String: Any]?)? {
        queue.sync {
            guard let merger, merger.addedFrames > 0,
                  let output = PRMNightMerger.makePixelBuffer(width: merger.width, height: merger.height, format: kCVPixelFormatType_64RGBAHalf),
                  merger.finish(into: output)
            else { return nil }
            self.merger = nil
            referenceSmall = nil
            conversionBuffer = nil
            return (output, referenceAttachments)
        }
    }
}
