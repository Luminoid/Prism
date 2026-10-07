import AVFoundation
import Testing
@testable import PrismCore

/// Portrait readiness: the pure evaluation, light and sampling helpers, the debouncer, and the
/// monitor on a session without a camera (the simulator has none).
struct PRMPortraitReadinessTests {
    // MARK: - Evaluation

    @Test
    func `Distance maps to the system Camera's hints`() {
        let thresholds = PRMPortraitReadiness.Thresholds(minimumDistance: 0.5, maximumDistance: 2.5)
        #expect(PRMPortraitReadiness.evaluate(distance: 0.3, isLowLight: false, thresholds: thresholds) == .moveFarther)
        #expect(PRMPortraitReadiness.evaluate(distance: 1.2, isLowLight: false, thresholds: thresholds) == .ready)
        #expect(PRMPortraitReadiness.evaluate(distance: 4, isLowLight: false, thresholds: thresholds) == .moveCloser)
        #expect(PRMPortraitReadiness.evaluate(distance: nil, isLowLight: false, thresholds: thresholds) == .searching)
        #expect(PRMPortraitReadiness.evaluate(distance: .nan, isLowLight: false, thresholds: thresholds) == .searching)
    }

    @Test
    func `Low light wins over distance`() {
        #expect(PRMPortraitReadiness.evaluate(distance: 1.2, isLowLight: true) == .needsMoreLight)
        #expect(PRMPortraitReadiness.evaluate(distance: nil, isLowLight: true) == .needsMoreLight)
    }

    @Test
    func `Low light means auto exposure ran out of room`() {
        // Can't reach the target by more than a stop.
        #expect(PRMPortraitReadiness.isLowLight(iso: 400, maxISO: 6400, exposureDuration: 1.0 / 60, targetOffset: -1.5))
        // ISO near its maximum with a long shutter.
        #expect(PRMPortraitReadiness.isLowLight(iso: 5800, maxISO: 6400, exposureDuration: 1.0 / 15, targetOffset: -0.2))
        // High ISO alone, with a short shutter, is still fine.
        #expect(!PRMPortraitReadiness.isLowLight(iso: 5800, maxISO: 6400, exposureDuration: 1.0 / 60, targetOffset: 0))
        #expect(!PRMPortraitReadiness.isLowLight(iso: 100, maxISO: 6400, exposureDuration: 1.0 / 120, targetOffset: 0))
        #expect(!PRMPortraitReadiness.isLowLight(iso: 100, maxISO: 0, exposureDuration: 1, targetOffset: .nan))
    }

    @Test
    func `The near limit follows the lens's minimum focus distance`() {
        #expect(PRMPortraitReadiness.Thresholds.forLens(minimumFocusDistance: 150).minimumDistance == 0.5)
        let telephoto = PRMPortraitReadiness.Thresholds.forLens(minimumFocusDistance: 1000)
        #expect(abs(telephoto.minimumDistance - 1.2) < 0.0001)
        #expect(telephoto.maximumDistance == 2.5)
        #expect(PRMPortraitReadiness.Thresholds.forLens(minimumFocusDistance: -1).minimumDistance == 0.5)
    }

    // MARK: - Region

    @Test
    func `The largest face or body is measured, shrunk to its middle`() {
        let small = PRMDetectedObject(kind: .face, bounds: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let large = PRMDetectedObject(kind: .humanBody, bounds: CGRect(x: 0.4, y: 0.2, width: 0.4, height: 0.6))
        let salient = PRMDetectedObject(kind: .salientObject, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        let region = PRMPortraitReadiness.subjectRegion(detections: [small, large, salient], focusPoint: .zero)
        #expect(region == CGRect(x: 0.5, y: 0.35, width: 0.2, height: 0.3))
    }

    @Test
    func `Without a subject the focus point is measured`() {
        let center = PRMPortraitReadiness.subjectRegion(detections: [], focusPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(center.midX - 0.5) < 0.0001)
        #expect(abs(center.width - 0.2) < 0.0001)
        // Clipped to the frame at the edge.
        let corner = PRMPortraitReadiness.subjectRegion(detections: [], focusPoint: CGPoint(x: 1, y: 0))
        #expect(corner.maxX <= 1)
        #expect(corner.minY >= 0)
        #expect(corner.width > 0)
    }

    // MARK: - Depth sampling

    @Test
    func `The median skips holes and stays inside the region`() throws {
        // Left half 1.0 m, right half 3.0 m, with NaN and zero holes in the left half.
        let map = try makeDepthMap(width: 64, height: 48) { x, y in
            if x < 32 {
                if (x + y) % 7 == 0 { return .nan }
                if (x + y) % 11 == 0 { return 0 }
                return 1.0
            }
            return 3.0
        }
        let left = PRMPortraitReadiness.medianDepth(in: CGRect(x: 0, y: 0, width: 0.5, height: 1), of: map)
        #expect(left == 1.0)
        let right = PRMPortraitReadiness.medianDepth(in: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), of: map)
        #expect(right == 3.0)
        #expect(PRMPortraitReadiness.medianDepth(in: CGRect(x: 2, y: 2, width: 1, height: 1), of: map) == nil)
    }

    @Test
    func `A region of holes or another pixel format has no reading`() throws {
        let holes = try makeDepthMap(width: 16, height: 16) { _, _ in .nan }
        #expect(PRMPortraitReadiness.medianDepth(in: CGRect(x: 0, y: 0, width: 1, height: 1), of: holes) == nil)
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &bgra)
        let buffer = try #require(bgra)
        #expect(PRMPortraitReadiness.medianDepth(in: CGRect(x: 0, y: 0, width: 1, height: 1), of: buffer) == nil)
    }

    // MARK: - Debouncer

    @Test
    func `A new state must repeat before it's reported`() {
        var debouncer = PRMPortraitReadinessDebouncer(requiredRepeats: 2)
        #expect(debouncer.feed(.searching) == .searching)
        #expect(debouncer.feed(.ready) == nil)
        #expect(debouncer.feed(.ready) == .ready)
        // One stray sample doesn't switch, and resets the candidate.
        #expect(debouncer.feed(.moveCloser) == nil)
        #expect(debouncer.feed(.ready) == nil)
        #expect(debouncer.feed(.moveCloser) == nil)
        #expect(debouncer.feed(.moveCloser) == .moveCloser)
        // Unavailable passes at once.
        #expect(debouncer.feed(.unavailable) == .unavailable)
        #expect(debouncer.current == .unavailable)
    }

    // MARK: - Monitor

    @Test
    func `Without a camera the monitor reports unavailable`() async throws {
        let session = PRMCameraSession()
        let monitor = PRMPortraitReadinessMonitor(session: session)
        #expect(monitor.current == .searching)
        try await monitor.start()
        #expect(monitor.current == .unavailable)
        var iterator = monitor.readinessStream().makeAsyncIterator()
        #expect(await iterator.next() == .unavailable)
        await monitor.stop()
        #expect(monitor.current == .searching)
    }

    // MARK: - Helpers

    private func makeDepthMap(width: Int, height: Int, value: (Int, Int) -> Float) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32, nil, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0 ..< width {
                row[x] = value(x, y)
            }
        }
        return buffer
    }
}
