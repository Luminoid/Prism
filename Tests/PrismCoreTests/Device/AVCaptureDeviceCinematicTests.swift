import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+Cinematic.swift`.
struct AVCaptureDeviceCinematicTests {
    @Test
    func `Unit point clamps both axes`() {
        #expect(AVCaptureDevice.prm_clampedUnitPoint(CGPoint(x: 0.3, y: 0.7)) == CGPoint(x: 0.3, y: 0.7))
        #expect(AVCaptureDevice.prm_clampedUnitPoint(CGPoint(x: -1, y: 2)) == CGPoint(x: 0, y: 1))
        // AVFoundation raises on a NaN point of interest; it becomes the center.
        #expect(AVCaptureDevice.prm_clampedUnitPoint(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `No cinematic format among no formats`() {
        guard #available(iOS 26.0, *) else { return }
        let best = AVCaptureDevice.prm_bestCinematicFormat(
            from: [],
            preferredDimensions: CMVideoDimensions(width: 1920, height: 1080)
        )
        #expect(best == nil)
    }

    @Test
    func `Public signatures compile`() {
        let scenes: KeyPath<AVCaptureDevice, Set<PRMSceneMonitoringStatus>> = \.prm_cinematicSceneStatuses
        let aperture: KeyPath<AVCaptureDevice.Format, ClosedRange<Float>?> = \.prm_simulatedApertureRange
        _ = (scenes, aperture)
        if #available(iOS 26.0, *) {
            let focus: (AVCaptureDevice) -> (PRMCinematicFocusRequest) throws -> Void = { device in device.prm_setCinematicFocus }
            _ = focus
        }
    }
}
