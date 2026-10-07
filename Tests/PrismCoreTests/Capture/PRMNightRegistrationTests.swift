import CoreImage
import simd
import Testing
@testable import PrismCore

/// `PRMNightRegistration`: the matrix conversion (pure), Vision's convention on real images,
/// plausibility, sharpness and ghost thresholds.
struct PRMNightRegistrationTests {
    @Test
    func `A Vision translation becomes the opposite shift at full resolution, top-left origin`() {
        // Vision moves the floating image onto the reference by (tx, ty), origin bottom-left:
        // reference = frame + (tx, ty). Top-left at 4× scale: frame = reference + (-4 tx, +4 ty).
        let vision = simd_float3x3(rows: [
            SIMD3(1, 0, -3),
            SIMD3(0, 1, 2),
            SIMD3(0, 0, 1),
        ])
        let warp = PRMNightRegistration.referenceToFrameWarp(
            vision: vision,
            smallSize: SIMD2(100, 75),
            fullSize: SIMD2(400, 300)
        )
        let mapped = warp * SIMD3<Float>(200, 150, 1)
        #expect(abs(mapped.x / mapped.z - 212) < 1e-3)
        #expect(abs(mapped.y / mapped.z - 158) < 1e-3)
    }

    @Test
    func `Vision's registration maps reference pixels onto the shifted frame`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        // Small images 512×384 for a 2048×1536 frame. The floating frame's content sits 12 px
        // right and 7 px down (top-left), so at full size a reference pixel p is frame pixel
        // p + (48, 28).
        let texture = NightTestImages.texture(width: 600, height: 480)
        let reference = try #require(NightTestImages.render(texture, width: 512, height: 384, context: context))
        let shifted = texture.transformed(by: CGAffineTransform(translationX: 12, y: -7))
        let floating = try #require(NightTestImages.render(shifted, width: 512, height: 384, context: context))
        let registration = PRMNightRegistration(fullWidth: 2048, fullHeight: 1536, context: context)
        let warp = try #require(registration.warp(floatingSmall: floating, referenceSmall: reference))
        let mapped = warp * SIMD3<Float>(1000, 700, 1)
        let point = SIMD2(mapped.x / mapped.z, mapped.y / mapped.z)
        #expect(abs(point.x - 1048) < 4, "mapped to \(point)")
        #expect(abs(point.y - 728) < 4, "mapped to \(point)")
    }

    @Test
    func `The right warp matches better than none, and a frame matches itself exactly`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let texture = NightTestImages.texture(width: 300, height: 240)
        let reference = try #require(NightTestImages.render(texture, width: 256, height: 192, context: context))
        let shifted = try #require(NightTestImages.render(texture.transformed(by: CGAffineTransform(translationX: 6, y: -4)), width: 256, height: 192, context: context))
        #expect(PRMNightRegistration.alignmentError(reference: reference, floating: reference, warp: matrix_identity_float3x3) == 0)
        // Reference pixel p sits at p + (6, 4) in the shifted frame (top-left origin).
        let correct = simd_float3x3(rows: [SIMD3(1, 0, 6), SIMD3(0, 1, 4), SIMD3(0, 0, 1)])
        let aligned = PRMNightRegistration.alignmentError(reference: reference, floating: shifted, warp: correct)
        let unaligned = PRMNightRegistration.alignmentError(reference: reference, floating: shifted, warp: matrix_identity_float3x3)
        #expect(aligned < unaligned / 4)
    }

    @Test
    func `Warps that fold or fly off are implausible`() {
        let size = SIMD2<Float>(400, 300)
        #expect(PRMNightRegistration.isPlausible(matrix_identity_float3x3, fullSize: size))
        let small = simd_float3x3(rows: [SIMD3(1, 0, 10), SIMD3(0, 1, -8), SIMD3(0, 0, 1)])
        #expect(PRMNightRegistration.isPlausible(small, fullSize: size))
        let far = simd_float3x3(rows: [SIMD3(1, 0, 120), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
        #expect(!PRMNightRegistration.isPlausible(far, fullSize: size))
        let folded = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)])
        #expect(!PRMNightRegistration.isPlausible(folded, fullSize: size))
    }

    @Test
    func `A blurred frame scores lower sharpness`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let texture = NightTestImages.texture(width: 256, height: 192)
        let sharp = try #require(NightTestImages.render(texture, width: 256, height: 192, context: context))
        let blurred = try #require(NightTestImages.render(
            texture.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: texture.extent),
            width: 256,
            height: 192,
            context: context
        ))
        #expect(PRMNightRegistration.sharpness(sharp) > 2 * PRMNightRegistration.sharpness(blurred))
    }

    @Test
    func `Ghost thresholds rise with ISO and stay bounded`() {
        let low = PRMNightRegistration.ghostThresholds(iso: 100)
        let high = PRMNightRegistration.ghostThresholds(iso: 6400)
        #expect(low.low == 0.10)
        #expect(high.low > low.low)
        #expect(high.low <= 0.30)
        #expect(high.high > high.low)
        #expect(PRMNightRegistration.ghostThresholds(iso: 1_000_000).low == 0.30)
    }

    @Test
    func `Small copies are a quarter of the frame`() throws {
        let context = try #require(PRMRenderContext()).ciContext
        let registration = PRMNightRegistration(fullWidth: 400, fullHeight: 300, context: context)
        let frame = try #require(NightTestImages.bgraBuffer(width: 400, height: 300) { _, _ in (128, 128, 128) })
        let small = try #require(registration.makeSmall(frame))
        #expect(CVPixelBufferGetWidth(small) == 100)
        #expect(CVPixelBufferGetHeight(small) == 75)
    }
}
