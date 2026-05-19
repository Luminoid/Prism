import AVFoundation
import Testing
@testable import PrismCore

struct PRMCameraStateTests {
    @Test
    func `Default state is sensible`() {
        let state = PRMCameraState()
        #expect(!state.isRunning)
        #expect(state.zoomFactor == 1.0)
        #expect(state.torchMode == .off)
        #expect(state.torchLevel == 0)
        #expect(state.focusMode == .continuousAutoFocus)
        #expect(state.lensPosition == 0)
        #expect(state.exposureMode == .continuousAutoExposure)
        #expect(state.whiteBalanceMode == .continuousAutoWhiteBalance)
        #expect(state.whiteBalanceTemperature == 5500)
        #expect(state.whiteBalanceTint == 0)
        #expect(state.frameRate == nil)
        #expect(!state.isVideoHDREnabled)
        #expect(!state.isLowLightBoostActive)
        #expect(!state.isInterrupted)
    }

    @Test
    func `State is equatable`() {
        var a = PRMCameraState()
        let b = PRMCameraState()
        #expect(a == b)
        a.iso = 200
        #expect(a != b)
    }

    @Test
    func `Lens position and HDR fields are wired`() {
        var state = PRMCameraState()
        state.lensPosition = 0.42
        state.isVideoHDREnabled = true
        state.isLowLightBoostActive = true
        #expect(state.lensPosition == 0.42)
        #expect(state.isVideoHDREnabled)
        #expect(state.isLowLightBoostActive)
    }
}
