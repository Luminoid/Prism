import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+WhiteBalance.swift`. Device-touching paths require a real
/// camera (simulator returns nil from `AVCaptureDevice.default`), so we cover the value
/// types and preset table — the part that doesn't depend on hardware.
struct AVCaptureDeviceWhiteBalanceTests {
    typealias TempTint = AVCaptureDevice.PRMTemperatureAndTint
    typealias Preset = AVCaptureDevice.PRMWhiteBalancePreset

    @Test
    func `PRMTemperatureAndTint defaults tint to 0`() {
        let value = TempTint(temperature: 5500)
        #expect(value.temperature == 5500)
        #expect(value.tint == 0)
    }

    @Test
    func `PRMTemperatureAndTint equality`() {
        #expect(TempTint(temperature: 5500, tint: 0) == TempTint(temperature: 5500))
        #expect(TempTint(temperature: 5500, tint: 5) != TempTint(temperature: 5500, tint: -5))
        #expect(TempTint(temperature: 6500) != TempTint(temperature: 5500))
    }

    @Test
    func `Standard preset Kelvin values match photography conventions`() {
        // These are public Kelvin values consumers reference in UI ("Tungsten 3200K").
        // Pinning them prevents drift if someone re-tunes one preset without realizing.
        #expect(Preset.tungsten.temperature == 3200)
        #expect(Preset.fluorescent.temperature == 4000)
        #expect(Preset.flash.temperature == 5400)
        #expect(Preset.daylight.temperature == 5500)
        #expect(Preset.cloudy.temperature == 6500)
        #expect(Preset.shade.temperature == 7500)
    }

    @Test
    func `Preset CaseIterable covers all six values`() {
        #expect(Preset.allCases.count == 6)
        let temps = Preset.allCases.map(\.temperature).sorted()
        // Warmest → coolest, monotonically increasing.
        #expect(temps == [3200, 4000, 5400, 5500, 6500, 7500])
    }

    @Test
    func `Sendable across actor hops`() async {
        let result = await Task.detached { TempTint(temperature: 5500, tint: 10) }.value
        #expect(result == TempTint(temperature: 5500, tint: 10))
    }
}
