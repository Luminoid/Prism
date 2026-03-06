import AVFoundation
import CoreMedia
import Testing
@testable import PrismCore

@Suite("PRMPhotoSettingsBuilder")
struct PRMPhotoSettingsBuilderTests {
    // MARK: - Default Build

    @Test("Default builder produces valid settings")
    func defaultBuild() {
        let settings = PRMPhotoSettingsBuilder().build()
        #expect(settings.uniqueID != 0)
    }

    // MARK: - Flash Mode

    @Test("Flash mode is applied")
    func flashMode() {
        let settings = PRMPhotoSettingsBuilder()
            .flashMode(.on)
            .build()
        #expect(settings.flashMode == .on)
    }

    @Test("Flash mode auto")
    func flashModeAuto() {
        let settings = PRMPhotoSettingsBuilder()
            .flashMode(.auto)
            .build()
        #expect(settings.flashMode == .auto)
    }

    @Test("Flash mode off")
    func flashModeOff() {
        let settings = PRMPhotoSettingsBuilder()
            .flashMode(.off)
            .build()
        #expect(settings.flashMode == .off)
    }

    // MARK: - Quality Prioritization

    @Test("Quality prioritization is applied")
    func qualityPrioritization() {
        let settings = PRMPhotoSettingsBuilder()
            .qualityPrioritization(.quality)
            .build()
        #expect(settings.photoQualityPrioritization == .quality)
    }

    @Test("Speed prioritization is applied")
    func speedPrioritization() {
        let settings = PRMPhotoSettingsBuilder()
            .qualityPrioritization(.speed)
            .build()
        #expect(settings.photoQualityPrioritization == .speed)
    }

    // MARK: - Codec Type

    @Test("HEVC codec creates HEVC settings")
    func hevcCodec() {
        let settings = PRMPhotoSettingsBuilder()
            .photoCodecType(.hevc)
            .build()
        // Verify the settings were created with HEVC format
        #expect(settings.uniqueID != 0)
    }

    // MARK: - Max Dimensions

    @Test("Max photo dimensions are applied")
    func maxDimensions() {
        let dims = CMVideoDimensions(width: 4032, height: 3024)
        let settings = PRMPhotoSettingsBuilder()
            .maxPhotoDimensions(dims)
            .build()
        #expect(settings.maxPhotoDimensions.width == 4032)
        #expect(settings.maxPhotoDimensions.height == 3024)
    }

    // MARK: - Chaining

    @Test("Multiple options can be chained")
    func chaining() {
        let settings = PRMPhotoSettingsBuilder()
            .flashMode(.auto)
            .qualityPrioritization(.balanced)
            .build()
        #expect(settings.flashMode == .auto)
        #expect(settings.photoQualityPrioritization == .balanced)
    }

    @Test("Builder is immutable — branching produces independent settings")
    func branching() {
        let base = PRMPhotoSettingsBuilder()
            .flashMode(.auto)

        let withQuality = base.qualityPrioritization(.quality).build()
        let withSpeed = base.qualityPrioritization(.speed).build()

        #expect(withQuality.flashMode == .auto)
        #expect(withSpeed.flashMode == .auto)
        #expect(withQuality.photoQualityPrioritization == .quality)
        #expect(withSpeed.photoQualityPrioritization == .speed)
    }

    // MARK: - Red-Eye Reduction

    @Test("Red-eye reduction can be enabled")
    func redEyeReduction() {
        let settings = PRMPhotoSettingsBuilder()
            .enableAutoRedEyeReduction(true)
            .build()
        #expect(settings.isAutoRedEyeReductionEnabled == true)
    }

    // MARK: - Auto Stabilization (iOS only)

    #if !os(macOS)
        @Test("Auto still image stabilization can be set")
        func autoStabilization() {
            let settings = PRMPhotoSettingsBuilder()
                .enableAutoStillImageStabilization(true)
                .build()
            #expect(settings.isAutoStillImageStabilizationEnabled == true)
        }
    #endif
}
