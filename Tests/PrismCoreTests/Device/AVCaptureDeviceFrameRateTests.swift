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

    @Test
    func `A rate at a range's end uses the range's own duration`() {
        // 29.97 fps is 1001/30000 s; Int32(29.97) used to truncate it to 1/29.
        let ntsc = CMTime(value: 1001, timescale: 30000)
        let duration = AVCaptureDevice.prm_frameDuration(forFPS: 29.97, min: ntsc, max: CMTime(value: 1, timescale: 2))
        #expect(CMTimeCompare(duration, ntsc) == 0)
    }

    @Test
    func `A rate inside a range is exact and stays inside it`() {
        let lower = CMTime(value: 1, timescale: 240)
        let upper = CMTime(value: 1, timescale: 1)
        let sixty = AVCaptureDevice.prm_frameDuration(forFPS: 60, min: lower, max: upper)
        #expect(abs(CMTimeGetSeconds(sixty) - 1.0 / 60) < 1e-6)
        // A sub-1 fps request no longer becomes an invalid time (timescale 0).
        let slow = AVCaptureDevice.prm_frameDuration(forFPS: 0.5, min: lower, max: upper)
        #expect(slow.isValid)
        #expect(CMTimeCompare(slow, upper) == 0)
    }

    @Test
    func `Frame rate of a duration`() {
        #expect(AVCaptureDevice.prm_frameRate(of: CMTime(value: 1, timescale: 30)) == 30)
        #expect(AVCaptureDevice.prm_frameRate(of: .invalid) == 0)
    }
}
