import AVFoundation
import Testing
@testable import PrismCore

struct PRMPhotoSettingsTests {
    @Test
    func defaults() {
        let settings = PRMPhotoSettings()
        #expect(settings.flashMode == .off)
        #expect(settings.qualityPrioritization == .balanced)
        #expect(settings.codec == nil)
        #expect(settings.maxDimensions == nil)
        #expect(settings.autoRedEyeReduction == nil)
        #expect(settings.depthDataDelivery == nil)
        #expect(settings.portraitEffectsMatte == nil)
        #expect(settings.rotationAngle == nil)
    }

    @Test
    func `Fluent builder chains`() {
        let settings = PRMPhotoSettings()
            .flashMode(.auto)
            .qualityPrioritization(.quality)
            .codec(.hevc)
            .autoRedEyeReduction(true)
            .portraitEffectsMatte(true)
            .rotationAngle(90)
        #expect(settings.flashMode == .auto)
        #expect(settings.qualityPrioritization == .quality)
        #expect(settings.codec == .hevc)
        #expect(settings.autoRedEyeReduction == true)
        #expect(settings.portraitEffectsMatte == true)
        #expect(settings.rotationAngle == 90)
    }

    @Test
    func `Materialized settings never exceed the output's quality maximum`() {
        let output = AVCapturePhotoOutput()
        output.maxPhotoQualityPrioritization = .speed
        let av = PRMPhotoSettings()
            .flashMode(.auto)
            .qualityPrioritization(.quality)
            .makeAVSettings(for: output)
        #expect(av.flashMode == .auto)
        #expect(av.photoQualityPrioritization == .speed)
    }

    @Test
    func `Quality is lowered to the maximum, never raised`() {
        #expect(PRMPhotoSettings.clampedQuality(.quality, max: .balanced) == .balanced)
        #expect(PRMPhotoSettings.clampedQuality(.balanced, max: .speed) == .speed)
        #expect(PRMPhotoSettings.clampedQuality(.speed, max: .quality) == .speed)
        #expect(PRMPhotoSettings.clampedQuality(.quality, max: .quality) == .quality)
    }

    @Test
    func `Requested dimensions must be supported and fit the ceiling`() {
        let twelve = CMVideoDimensions(width: 4032, height: 3024)
        let fortyEight = CMVideoDimensions(width: 8064, height: 6048)
        let supported = [twelve, fortyEight]
        // Supported and under the ceiling: kept.
        #expect(same(PRMPhotoSettings.validatedMaxDimensions(fortyEight, supported: supported, ceiling: fortyEight), fortyEight))
        // Over the ceiling: the largest supported entry that fits.
        #expect(same(PRMPhotoSettings.validatedMaxDimensions(fortyEight, supported: supported, ceiling: twelve), twelve))
        // Not a supported entry: the largest supported one below it.
        let odd = CMVideoDimensions(width: 5000, height: 4000)
        #expect(same(PRMPhotoSettings.validatedMaxDimensions(odd, supported: supported, ceiling: fortyEight), twelve))
        // Nothing fits: dropped.
        let tiny = CMVideoDimensions(width: 640, height: 480)
        #expect(same(PRMPhotoSettings.validatedMaxDimensions(tiny, supported: supported, ceiling: fortyEight), nil))
        // A zero ceiling (output rebuilding) only checks the supported list.
        let zero = CMVideoDimensions(width: 0, height: 0)
        #expect(same(PRMPhotoSettings.validatedMaxDimensions(fortyEight, supported: supported, ceiling: zero), fortyEight))
    }

    @Test
    func `Unsupported dimensions are dropped for an output without a camera`() {
        let av = PRMPhotoSettings()
            .maxDimensions(CMVideoDimensions(width: 8064, height: 6048))
            .makeAVSettings(for: AVCapturePhotoOutput())
        // No device feeds a bare output, so nothing is supported and the default stays.
        #expect(av.maxPhotoDimensions.width == 0 || av.maxPhotoDimensions.width != 8064)
    }
}

/// `CMVideoDimensions` isn't `Equatable`.
private func same(_ lhs: CMVideoDimensions?, _ rhs: CMVideoDimensions?) -> Bool {
    lhs?.width == rhs?.width && lhs?.height == rhs?.height
}
