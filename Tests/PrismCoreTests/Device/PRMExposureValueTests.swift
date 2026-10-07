import AVFoundation
import Testing
@testable import PrismCore

struct PRMExposureValueTests {
    @Test
    func `fixedValue is only set for fixed axes`() {
        #expect(PRMExposureValue<Float>.fixed(2.8).fixedValue == 2.8)
        #expect(PRMExposureValue<Float>.auto.fixedValue == nil)
        #expect(PRMExposureValue<Float>.current.fixedValue == nil)
    }

    @Test
    func `isAuto is only true for auto`() {
        #expect(PRMExposureValue<Double>.auto.isAuto)
        #expect(!PRMExposureValue<Double>.current.isAuto)
        #expect(!PRMExposureValue<Double>.fixed(1.0 / 250).isAuto)
    }

    @Test
    func `Clamping only touches fixed values`() {
        #expect(PRMExposureValue<Float>.fixed(6400).clamped(to: 50 ... 3200) == .fixed(3200))
        #expect(PRMExposureValue<Float>.fixed(20).clamped(to: 50 ... 3200) == .fixed(50))
        #expect(PRMExposureValue<Float>.fixed(400).clamped(to: nil) == .fixed(400))
        #expect(PRMExposureValue<Float>.auto.clamped(to: 50 ... 3200) == .auto)
        #expect(PRMExposureValue<Float>.current.clamped(to: 50 ... 3200) == .current)
    }

    @Test
    func `Axes from per-axis flags`() {
        #expect(PRMExposureAxes(apertureAuto: true, shutterAuto: true, isoAuto: true) == .all)
        #expect(PRMExposureAxes(apertureAuto: false, shutterAuto: false, isoAuto: false).isEmpty)
        #expect(PRMExposureAxes(apertureAuto: true, shutterAuto: false, isoAuto: true) == [.aperture, .iso])
    }

    @Test
    func `Axes from exposure mode before iOS 27`() {
        #expect(PRMExposureAxes(exposureMode: .continuousAutoExposure) == .all)
        #expect(PRMExposureAxes(exposureMode: .autoExpose) == .all)
        #expect(PRMExposureAxes(exposureMode: .custom).isEmpty)
        #expect(PRMExposureAxes(exposureMode: .locked).isEmpty)
    }

    @Test(.enabled(if: OSAvailability.isIOS27))
    func `Exposure signals round-trip through AVFoundation`() {
        guard #available(iOS 27.0, *) else { return }
        for signal in PRMExposureSignal.allCases {
            #expect(PRMExposureSignal(signal.avSignal) == signal)
        }
        let avSet: Set<AVCaptureDeviceExposureSignal> = [.flicker, .document]
        #expect(PRMExposureSignal.set(from: avSet) == [.flicker, .document])
    }

    @Test
    func `Values cross actor boundaries`() async {
        let value = PRMExposureValue<Double>.fixed(0.004)
        let axes: PRMExposureAxes = [.shutter]
        let roundTrip = await Task.detached { (value, axes) }.value
        #expect(roundTrip.0 == value)
        #expect(roundTrip.1 == axes)
    }
}
