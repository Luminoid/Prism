import AVFoundation
import Testing
@testable import PrismCore

struct PRMSessionErrorTests {
    @Test
    func `Equatable cases`() {
        #expect(PRMSessionError.notAuthorized == PRMSessionError.notAuthorized)
        #expect(PRMSessionError.cancelled == PRMSessionError.cancelled)
        #expect(PRMSessionError.noVideoDevice(.back) == PRMSessionError.noVideoDevice(.back))
        #expect(PRMSessionError.noVideoDevice(.back) != PRMSessionError.noVideoDevice(.front))
    }

    @Test
    func `Localized description is non-empty for all cases`() {
        let cases: [PRMSessionError] = [
            .notAuthorized,
            .noVideoDevice(.back),
            .cannotCreateDeviceInput("test"),
            .cannotAttachToSession("test"),
            .photoCaptureFailed("test"),
            .videoRecordingFailed("test"),
            .cancelled,
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
