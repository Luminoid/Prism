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

    @Test
    func `iOS 26 and 27 fields default to off`() {
        let state = PRMCameraState()
        #expect(state.lensAperture == 0)
        #expect(state.autoExposureAxes == .all)
        #expect(state.activeExposureSignals.isEmpty)
        #expect(!state.isPrimaryConstituentLocked)
        #expect(state.lensSmudgeStatus == .disabled)
        #expect(!state.isLowLightVideoNoiseReductionActive)
        #expect(state.interruptionReason == nil)
        #expect(state.systemPressure == .nominal)
        #expect(!state.isContinuousAutoFocusTrackingEnabled)
        #expect(!state.isContinuousAutoFocusTrackingSubjectAcquired)
        #expect(state.continuousAutoFocusTrackingBias == 0)
        #expect(!state.isCinematicVideoCaptureEnabled)
        #expect(state.cinematicSimulatedAperture == 0)
        #expect(state.cinematicSceneStatuses.isEmpty)
        #expect(!state.isCinematicVideoMetadataCaptureEnabled)
        #expect(state.dynamicAspectRatio == nil)
        #expect(state.dynamicDimensions == nil)
    }
}
