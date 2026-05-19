import Testing
@testable import PrismCore

/// `PRMNightModeCapture` orchestrates real photo captures via `PRMPhotoCapture` so it can't
/// run end-to-end without a device. We lock the public API surface here.
struct PRMNightModeCaptureTests {
    @Test
    func `Public API surface compiles against documented key paths`() {
        let captureKP: KeyPath<PRMNightModeCapture, PRMPhotoCapture> = \PRMNightModeCapture.capture
        let contextKP: KeyPath<PRMNightModeCapture, PRMRenderContext> = \PRMNightModeCapture.context
        _ = (captureKP, contextKP)
        #expect(true)
    }
}
