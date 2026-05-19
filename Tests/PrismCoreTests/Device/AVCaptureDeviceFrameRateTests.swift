import AVFoundation
import Testing
@testable import PrismCore

/// Tests for `AVCaptureDevice+FrameRate.swift`.
///
/// Device-touching paths (`prm_setFrameRate`, `prm_currentFrameRate`, `prm_maxFrameRate`,
/// `prm_supportsSlowMotion`, `prm_supports(framesPerSecond:)`) need a real camera with real
/// supported formats; the simulator returns nil from `AVCaptureDevice.default`. The
/// `PRMFrameRateChange` value type is testable in isolation.
struct AVCaptureDeviceFrameRateTests {
    typealias Change = AVCaptureDevice.PRMFrameRateChange

    @Test
    func `PRMFrameRateChange stores applied fps and format-change flag`() {
        let change = Change(appliedFPS: 60, formatChanged: true)
        #expect(change.appliedFPS == 60)
        #expect(change.formatChanged == true)
    }

    @Test
    func `PRMFrameRateChange equality`() {
        #expect(Change(appliedFPS: 60, formatChanged: false) == Change(appliedFPS: 60, formatChanged: false))
        #expect(Change(appliedFPS: 60, formatChanged: false) != Change(appliedFPS: 60, formatChanged: true))
        #expect(Change(appliedFPS: 60, formatChanged: false) != Change(appliedFPS: 30, formatChanged: false))
    }

    @Test
    func `PRMFrameRateChange is Sendable across actor hops`() async {
        let result = await Task.detached { Change(appliedFPS: 240, formatChanged: true) }.value
        #expect(result == Change(appliedFPS: 240, formatChanged: true))
    }

    @Test
    func `Standard slow-mo rates are representable`() {
        // 120 fps and 240 fps are the canonical iPhone slow-mo rates.
        let onetwenty = Change(appliedFPS: 120, formatChanged: true)
        let twoforty = Change(appliedFPS: 240, formatChanged: true)
        #expect(onetwenty.appliedFPS == 120)
        #expect(twoforty.appliedFPS == 240)
    }
}
