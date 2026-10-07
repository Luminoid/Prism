import AVFoundation
import Testing
@testable import PrismCore

struct PRMCinematicVideoTests {
    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Focus modes round-trip through AVFoundation`() {
        guard #available(iOS 26.0, *) else { return }
        for mode in [PRMCinematicFocusMode.none, .strong, .weak] {
            #expect(PRMCinematicFocusMode(mode.avMode) == mode)
        }
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Scene status maps not-enough-light and keeps unknown strings`() {
        guard #available(iOS 26.0, *) else { return }
        #expect(PRMSceneMonitoringStatus(AVCaptureSceneMonitoringStatus.notEnoughLight) == .notEnoughLight)
        let future = AVCaptureSceneMonitoringStatus(rawValue: "PRMFutureStatus")
        #expect(PRMSceneMonitoringStatus(future) == .other("PRMFutureStatus"))
    }
}
