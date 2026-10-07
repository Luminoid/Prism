import AVFoundation
import Foundation
import Testing
@testable import PrismCore

/// Prism's categories and logging helpers. These tests never touch `PRMLog.handler` or
/// `PRMLog.minimumLevel`: both are process-wide, and the core suite (`PRMLogTests`) swaps
/// them while suites run in parallel.
struct PRMLogCategoriesTests {
    private enum SampleError: Error {
        case locked
    }

    @Test
    func `Categories keep the names Console filters on`() {
        #expect(PRMLog.Category.session.name == "Session")
        #expect(PRMLog.Category.capture.name == "Capture")
        #expect(PRMLog.Category.filter.name == "Filter")
        #expect(PRMLog.Category.preview.name == "Preview")
        #expect(PRMLog.Category.general.name == "General")
        #expect(PRMLog.subsystem == "dev.luminoid.prism")
    }

    @Test
    func `bestEffort returns the result, or nil when the call throws`() {
        #expect(PRMLog.bestEffort(.general, "categoriesTest.success") { 42 } == 42)
        let failed: Int? = PRMLog.bestEffort(.general, "categoriesTest.failure") { throw SampleError.locked }
        #expect(failed == nil)
        let throttled: Int? = PRMLog.bestEffort(.general, "categoriesTest.throttled", throttled: true) { throw SampleError.locked }
        #expect(throttled == nil)
        #expect(PRMLog.bestEffort(.general, "categoriesTest.throttled", throttled: true) { "recovered" } == "recovered")
    }

    @Test
    func `fourCC prints pixel formats as text and falls back to the number`() {
        #expect(PRMLog.fourCC(kCVPixelFormatType_32BGRA) == "BGRA")
        #expect(PRMLog.fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == "420f")
        #expect(PRMLog.fourCC(1) == "1")
    }

    @Test
    func `AVFoundation values have short log names`() {
        #expect(AVCaptureDevice.Position.back.prm_logName == "back")
        #expect(AVCaptureDevice.Position.front.prm_logName == "front")
        #expect(AVCaptureDevice.DeviceType.builtInTripleCamera.prm_logName == "BuiltInTripleCamera")
        #expect(AVCaptureSession.Preset.photo.prm_logName == "Photo")
        #expect(AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.prm_logName == "videoDeviceInUseByAnotherClient")
        #expect(ProcessInfo.ThermalState.serious.prm_logName == "serious")
    }

    @Test
    func `System pressure describes its level and factors`() {
        #expect(PRMSystemPressure.nominal.logDescription == "nominal")
        let hot = PRMSystemPressure(level: .serious, factors: [.systemTemperature, .cameraTemperature])
        #expect(hot.logDescription == "serious (systemTemperature, cameraTemperature)")
    }
}
