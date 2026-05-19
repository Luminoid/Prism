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
    }

    @Test
    func `Fluent builder chains`() {
        let settings = PRMPhotoSettings()
            .flashMode(.auto)
            .qualityPrioritization(.quality)
            .codec(.hevc)
            .autoRedEyeReduction(true)
        #expect(settings.flashMode == .auto)
        #expect(settings.qualityPrioritization == .quality)
        #expect(settings.codec == .hevc)
        #expect(settings.autoRedEyeReduction == true)
    }

    @Test
    func `Materializes AVCapturePhotoSettings`() {
        let av = PRMPhotoSettings()
            .flashMode(.auto)
            .qualityPrioritization(.quality)
            .codec(.hevc)
            .makeAVSettings()
        #expect(av.flashMode == .auto)
        #expect(av.photoQualityPrioritization == .quality)
    }
}
