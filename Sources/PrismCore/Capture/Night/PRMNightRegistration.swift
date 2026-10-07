import CoreImage
import CoreVideo
import simd
import Vision

/// Aligns Night frames to the reference: quarter-resolution copies, Vision's image
/// registration on them, and the conversion of Vision's matrix into the merge shader's.
///
/// Vision's `warpTransform` maps the floating image onto the reference in the pixels of the
/// images it was given, origin bottom-left. The shader wants the opposite direction (each
/// reference pixel looks up its frame pixel), at full resolution, origin top-left; see
/// ``referenceToFrameWarp(vision:smallSize:fullSize:)``. Not thread-safe: call from one queue.
final class PRMNightRegistration {
    /// Quarter resolution: a quarter of the noise, a sixteenth of the pixels.
    static let downscale: Double = 0.25

    let fullWidth: Int
    let fullHeight: Int
    let smallWidth: Int
    let smallHeight: Int
    private let context: CIContext
    private let sequenceHandler = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?

    init(fullWidth: Int, fullHeight: Int, context: CIContext) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        smallWidth = max(16, Int((Double(fullWidth) * Self.downscale).rounded()))
        smallHeight = max(16, Int((Double(fullHeight) * Self.downscale).rounded()))
        self.context = context
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: smallWidth,
            kCVPixelBufferHeightKey as String: smallHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    // MARK: - Downscale

    /// A quarter-resolution BGRA copy with the frame's encoded values (no color conversion),
    /// for registration, sharpness and ghost weights.
    func makeSmall(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var small: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &small)
        guard let small else { return nil }
        let source = CIImage(cvPixelBuffer: frame, options: [.colorSpace: NSNull()])
        let scaleY = Double(smallHeight) / Double(fullHeight)
        let scaleX = Double(smallWidth) / Double(fullWidth)
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY,
            kCIInputAspectRatioKey: scaleX / scaleY,
        ])
        context.render(scaled, to: small, bounds: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight), colorSpace: nil)
        return small
    }

    // MARK: - Registration

    /// The shader's warp (reference pixel to frame pixel, full resolution, top-left origin)
    /// aligning `floatingSmall` to `referenceSmall`, or `nil` when Vision finds no plausible
    /// alignment. Tries a homography, then a translation. A warp that matches the reference
    /// worse than no warp at all (Vision misjudges low-contrast, noisy frames) loses to the
    /// identity.
    func warp(floatingSmall: CVPixelBuffer, referenceSmall: CVPixelBuffer) -> simd_float3x3? {
        let smallSize = SIMD2(Float(smallWidth), Float(smallHeight))
        let fullSize = SIMD2(Float(fullWidth), Float(fullHeight))
        var candidate: simd_float3x3?
        let homography = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: floatingSmall, options: [:])
        if (try? sequenceHandler.perform([homography], on: referenceSmall)) != nil,
           let observation = homography.results?.first {
            let warp = Self.referenceToFrameWarp(vision: observation.warpTransform, smallSize: smallSize, fullSize: fullSize)
            if Self.isPlausible(warp, fullSize: fullSize) {
                candidate = warp
            }
        }
        if candidate == nil {
            let translation = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: floatingSmall, options: [:])
            if (try? sequenceHandler.perform([translation], on: referenceSmall)) != nil,
               let observation = translation.results?.first {
                let shift = observation.alignmentTransform
                let vision = simd_float3x3(rows: [
                    SIMD3(1, 0, Float(shift.tx)),
                    SIMD3(0, 1, Float(shift.ty)),
                    SIMD3(0, 0, 1),
                ])
                let warp = Self.referenceToFrameWarp(vision: vision, smallSize: smallSize, fullSize: fullSize)
                if Self.isPlausible(warp, fullSize: fullSize) {
                    candidate = warp
                }
            }
        }
        guard let candidate else { return nil }
        let toSmall = simd_float3x3(diagonal: SIMD3(smallSize.x / fullSize.x, smallSize.y / fullSize.y, 1))
        let smallWarp = toSmall * candidate * toSmall.inverse
        let warpedError = Self.alignmentError(reference: referenceSmall, floating: floatingSmall, warp: smallWarp)
        let identityError = Self.alignmentError(reference: referenceSmall, floating: floatingSmall, warp: matrix_identity_float3x3)
        return warpedError <= identityError ? candidate : matrix_identity_float3x3
    }

    /// Mean absolute luma difference between `reference` and `floating` looked up through
    /// `warp` (reference pixel to floating pixel, same size, top-left origin), on a 4-pixel
    /// grid. Points that map outside `floating` are skipped.
    static func alignmentError(reference: CVPixelBuffer, floating: CVPixelBuffer, warp: simd_float3x3) -> Float {
        let width = CVPixelBufferGetWidth(reference)
        let height = CVPixelBufferGetHeight(reference)
        guard CVPixelBufferGetWidth(floating) == width, CVPixelBufferGetHeight(floating) == height else { return .infinity }
        CVPixelBufferLockBaseAddress(reference, .readOnly)
        CVPixelBufferLockBaseAddress(floating, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(reference, .readOnly)
            CVPixelBufferUnlockBaseAddress(floating, .readOnly)
        }
        guard let referenceBase = CVPixelBufferGetBaseAddress(reference),
              let floatingBase = CVPixelBufferGetBaseAddress(floating)
        else { return .infinity }
        let referenceRow = CVPixelBufferGetBytesPerRow(reference)
        let floatingRow = CVPixelBufferGetBytesPerRow(floating)
        func luma(_ base: UnsafeMutableRawPointer, _ bytesPerRow: Int, _ x: Int, _ y: Int) -> Float {
            let pixel = (base + y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            return 0.0722 * Float(pixel[0]) + 0.7152 * Float(pixel[1]) + 0.2126 * Float(pixel[2])
        }
        var total: Float = 0
        var count: Float = 0
        for y in stride(from: 2, to: height - 2, by: 4) {
            for x in stride(from: 2, to: width - 2, by: 4) {
                let mapped = warp * SIMD3(Float(x) + 0.5, Float(y) + 0.5, 1)
                guard mapped.z > 0 else { continue }
                let sourceX = Int(mapped.x / mapped.z)
                let sourceY = Int(mapped.y / mapped.z)
                guard sourceX >= 0, sourceY >= 0, sourceX < width, sourceY < height else { continue }
                total += abs(luma(referenceBase, referenceRow, x, y) - luma(floatingBase, floatingRow, sourceX, sourceY))
                count += 1
            }
        }
        return count > 0 ? total / count : .infinity
    }

    /// Converts Vision's floating-to-reference matrix (small pixels, origin bottom-left) into
    /// reference-to-frame at full resolution, origin top-left:
    /// `S⁻¹ · F · H⁻¹ · F · S`, with `S` the full-to-small scale and `F` the vertical flip.
    static func referenceToFrameWarp(vision: simd_float3x3, smallSize: SIMD2<Float>, fullSize: SIMD2<Float>) -> simd_float3x3 {
        let scale = smallSize / fullSize
        let toSmall = simd_float3x3(diagonal: SIMD3(scale.x, scale.y, 1))
        let flip = simd_float3x3(rows: [
            SIMD3(1, 0, 0),
            SIMD3(0, -1, smallSize.y),
            SIMD3(0, 0, 1),
        ])
        return toSmall.inverse * flip * vision.inverse * flip * toSmall
    }

    /// Rejects warps that move a corner by more than 12% of the frame or fold it over: a
    /// failed registration, not hand shake.
    static func isPlausible(_ warp: simd_float3x3, fullSize: SIMD2<Float>) -> Bool {
        let limit = 0.12 * max(fullSize.x, fullSize.y)
        let corners: [SIMD2<Float>] = [.zero, SIMD2(fullSize.x, 0), SIMD2(0, fullSize.y), fullSize]
        for corner in corners {
            let mapped = warp * SIMD3(corner.x, corner.y, 1)
            guard mapped.z > 0, mapped.x.isFinite, mapped.y.isFinite else { return false }
            let point = SIMD2(mapped.x, mapped.y) / mapped.z
            if simd_length(point - corner) > limit { return false }
        }
        return true
    }

    // MARK: - Sharpness and ghosts

    /// Variance of the Laplacian of the luma of a BGRA image, on every other pixel: higher is
    /// sharper. Hand-shake blur during a long frame drops it sharply.
    static func sharpness(_ image: CVPixelBuffer) -> Float {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { return 0 }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return 0 }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        guard width > 4, height > 4 else { return 0 }
        func luma(_ x: Int, _ y: Int) -> Float {
            let pixel = (base + y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            // BGRA
            return 0.0722 * Float(pixel[0]) + 0.7152 * Float(pixel[1]) + 0.2126 * Float(pixel[2])
        }
        var sum: Float = 0
        var sumOfSquares: Float = 0
        var count: Float = 0
        for y in stride(from: 1, to: height - 1, by: 2) {
            for x in stride(from: 1, to: width - 1, by: 2) {
                let laplacian = 4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y) - luma(x, y - 1) - luma(x, y + 1)
                sum += laplacian
                sumOfSquares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean)
    }

    /// The relative luma differences (frame against reference, at quarter resolution) where a
    /// frame's weight starts to fall and where it reaches zero. Higher ISO means more noise in
    /// the difference, so the thresholds rise with it.
    static func ghostThresholds(iso: Float) -> (low: Float, high: Float) {
        let stops = log2(max(iso, 100) / 100)
        let low = min(max(0.10 + 0.03 * stops, 0.10), 0.30)
        return (low, low + 0.35)
    }
}
