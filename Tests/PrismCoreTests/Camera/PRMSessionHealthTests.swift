import AVFoundation
import Testing
@testable import PrismCore

struct PRMSessionHealthTests {
    @Test
    func `System pressure levels are ordered`() {
        typealias Level = PRMSystemPressure.Level
        #expect(Level.nominal < .fair)
        #expect(Level.fair < .serious)
        #expect(Level.serious < .critical)
        #expect(Level.critical < .shutdown)
    }

    @Test
    func `Nominal pressure has no factors`() {
        #expect(PRMSystemPressure.nominal.level == .nominal)
        #expect(PRMSystemPressure.nominal.factors.isEmpty)
    }

    @Test
    func `Pressure factors combine`() {
        let pressure = PRMSystemPressure(level: .serious, factors: [.cameraTemperature, .batteryStress])
        #expect(pressure.factors.contains(.batteryStress))
        #expect(!pressure.factors.contains(.peakPower))
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Smudge status maps from AVFoundation`() {
        guard #available(iOS 26.0, *) else { return }
        #expect(PRMLensSmudgeStatus(AVCaptureCameraLensSmudgeDetectionStatus.smudged) == .smudged)
        #expect(PRMLensSmudgeStatus(AVCaptureCameraLensSmudgeDetectionStatus.smudgeNotDetected) == .clean)
        #expect(PRMLensSmudgeStatus(AVCaptureCameraLensSmudgeDetectionStatus.unknown) == .unknown)
        #expect(PRMLensSmudgeStatus(AVCaptureCameraLensSmudgeDetectionStatus.disabled) == .disabled)
    }

    @Test
    func `Health values cross actor boundaries`() async {
        let value = (PRMSystemPressure(level: .fair), PRMLensSmudgeStatus.smudged, PRMDeferredStart.photoAndMovie)
        let roundTrip = await Task.detached { value }.value
        #expect(roundTrip.0 == value.0)
        #expect(roundTrip.1 == value.1)
        #expect(roundTrip.2 == value.2)
    }
}
