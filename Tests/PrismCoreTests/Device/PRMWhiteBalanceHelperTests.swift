import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMWhiteBalanceHelper")
struct PRMWhiteBalanceHelperTests {
    // MARK: - TemperatureAndTint

    @Test("TemperatureAndTint stores values")
    func temperatureAndTintInit() {
        let value = PRMWhiteBalanceHelper.TemperatureAndTint(temperature: 5500, tint: 0)
        #expect(value.temperature == 5500)
        #expect(value.tint == 0)
    }

    @Test("TemperatureAndTint is equatable")
    func temperatureAndTintEquatable() {
        let a = PRMWhiteBalanceHelper.TemperatureAndTint(temperature: 3200, tint: 10)
        let b = PRMWhiteBalanceHelper.TemperatureAndTint(temperature: 3200, tint: 10)
        let c = PRMWhiteBalanceHelper.TemperatureAndTint(temperature: 6500, tint: 0)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Preset

    @Test("Preset daylight temperature is 5500K")
    func presetDaylight() {
        #expect(PRMWhiteBalanceHelper.Preset.daylight.temperature == 5500)
    }

    @Test("Preset tungsten temperature is 3200K")
    func presetTungsten() {
        #expect(PRMWhiteBalanceHelper.Preset.tungsten.temperature == 3200)
    }

    @Test("Preset cloudy temperature is 6500K")
    func presetCloudy() {
        #expect(PRMWhiteBalanceHelper.Preset.cloudy.temperature == 6500)
    }

    @Test("Preset shade temperature is 7500K")
    func presetShade() {
        #expect(PRMWhiteBalanceHelper.Preset.shade.temperature == 7500)
    }

    @Test("Preset fluorescent temperature is 4000K")
    func presetFluorescent() {
        #expect(PRMWhiteBalanceHelper.Preset.fluorescent.temperature == 4000)
    }

    @Test("Preset flash temperature is 5400K")
    func presetFlash() {
        #expect(PRMWhiteBalanceHelper.Preset.flash.temperature == 5400)
    }

    @Test("All presets have unique temperatures")
    func allPresetsUnique() {
        let temperatures = PRMWhiteBalanceHelper.Preset.allCases.map(\.temperature)
        let uniqueTemperatures = Set(temperatures)
        #expect(uniqueTemperatures.count == PRMWhiteBalanceHelper.Preset.allCases.count)
    }

    @Test("Preset temperatures are ordered warm to cool")
    func presetsOrderedWarmToCool() {
        #expect(PRMWhiteBalanceHelper.Preset.tungsten.temperature < PRMWhiteBalanceHelper.Preset.daylight.temperature)
        #expect(PRMWhiteBalanceHelper.Preset.daylight.temperature < PRMWhiteBalanceHelper.Preset.cloudy.temperature)
        #expect(PRMWhiteBalanceHelper.Preset.cloudy.temperature < PRMWhiteBalanceHelper.Preset.shade.temperature)
    }

    // MARK: - Query Signatures

    @Test("Current temperature and tint returns struct")
    func currentTemperatureAndTintSignature() {
        let _: (AVCaptureDevice) -> PRMWhiteBalanceHelper.TemperatureAndTint =
            PRMWhiteBalanceHelper.currentTemperatureAndTint(for:)
    }

    @Test("Current white balance mode returns mode")
    func currentWhiteBalanceModeSignature() {
        let _: (AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceMode =
            PRMWhiteBalanceHelper.currentWhiteBalanceMode(for:)
    }

    // MARK: - Control Signatures

    @Test("Set white balance mode method exists")
    func setWhiteBalanceModeSignature() {
        let _: (AVCaptureDevice.WhiteBalanceMode, AVCaptureDevice) throws -> Void =
            PRMWhiteBalanceHelper.setWhiteBalanceMode(_:on:)
    }

    @Test("Lock white balance with temperature/tint method exists")
    func lockWhiteBalanceTemperatureSignature() {
        typealias Method = (PRMWhiteBalanceHelper.TemperatureAndTint, AVCaptureDevice, (@Sendable (CMTime) -> Void)?) throws -> Void
        let _: Method = PRMWhiteBalanceHelper.lockWhiteBalance(temperatureAndTint:on:completion:)
    }

    @Test("Lock white balance with preset method exists")
    func lockWhiteBalancePresetSignature() {
        typealias Method = (PRMWhiteBalanceHelper.Preset, AVCaptureDevice, (@Sendable (CMTime) -> Void)?) throws -> Void
        let _: Method = PRMWhiteBalanceHelper.lockWhiteBalance(preset:on:completion:)
    }
}
