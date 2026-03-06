import AVFoundation
import Testing
@testable import PrismCore

// MARK: - PRMPhotoCaptureProcessorTests

@Suite("PRMPhotoCaptureProcessor")
struct PRMPhotoCaptureProcessorTests {
    // MARK: - Initialization

    @Test("Stores photo settings")
    func storesSettings() {
        let settings = AVCapturePhotoSettings()
        let processor = PRMPhotoCaptureProcessor(settings: settings)
        #expect(processor.photoSettings.uniqueID == settings.uniqueID)
    }

    @Test("Captured photo data is nil initially")
    func initialPhotoDataNil() {
        let processor = PRMPhotoCaptureProcessor(settings: AVCapturePhotoSettings())
        #expect(processor.capturedPhotoData == nil)
    }

    // MARK: - Callbacks

    @Test("Will capture photo handler can be set")
    func willCaptureHandler() {
        let processor = PRMPhotoCaptureProcessor(settings: AVCapturePhotoSettings())
        var called = false
        processor.willCapturePhotoHandler = { called = true }
        processor.willCapturePhotoHandler?()
        #expect(called)
    }

    @Test("Completion handler can be set")
    func completionHandler() {
        let processor = PRMPhotoCaptureProcessor(settings: AVCapturePhotoSettings())
        var completed = false
        processor.completionHandler = { _ in completed = true }
        processor.completionHandler?(processor)
        #expect(completed)
    }

    @Test("Processing started handler can be set")
    func processingStartedHandler() {
        let processor = PRMPhotoCaptureProcessor(settings: AVCapturePhotoSettings())
        var isProcessing: Bool?
        processor.processingStartedHandler = { isProcessing = $0 }
        processor.processingStartedHandler?(true)
        #expect(isProcessing == true)
    }

    @Test("Photo processing handler can be set")
    func photoProcessingHandler() {
        let processor = PRMPhotoCaptureProcessor(
            settings: AVCapturePhotoSettings(),
            photoProcessingHandler: { _ in Data() },
        )
        #expect(processor.photoProcessingHandler != nil)
    }
}
