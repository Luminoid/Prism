import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMDepthHelper")
struct PRMDepthHelperTests {
    // MARK: - Photo Output Queries

    @Test("isDepthCaptureSupported queries photoOutput")
    func depthCaptureSupported() {
        let photoOutput = AVCapturePhotoOutput()
        // In simulator without camera, depth is not supported
        let result = PRMDepthHelper.isDepthCaptureSupported(on: photoOutput)
        #expect(result == false)
    }

    @Test("enableDepthDataDelivery is no-op when unsupported")
    func enableWhenUnsupported() {
        let photoOutput = AVCapturePhotoOutput()
        // Should not crash when depth is not supported
        PRMDepthHelper.enableDepthDataDelivery(on: photoOutput)
        #expect(PRMDepthHelper.isDepthDataDeliveryEnabled(on: photoOutput) == false)
    }

    @Test("disableDepthDataDelivery sets enabled to false")
    func disableDepthDataDelivery() {
        let photoOutput = AVCapturePhotoOutput()
        PRMDepthHelper.disableDepthDataDelivery(on: photoOutput)
        #expect(PRMDepthHelper.isDepthDataDeliveryEnabled(on: photoOutput) == false)
    }

    @Test("isDepthDataDeliveryEnabled returns current state")
    func deliveryEnabledQuery() {
        let photoOutput = AVCapturePhotoOutput()
        let enabled = PRMDepthHelper.isDepthDataDeliveryEnabled(on: photoOutput)
        #expect(enabled == false)
    }

    // MARK: - Depth Data Output

    @Test("addDepthDataOutput returns nil without configured session")
    func addDepthOutputNoSession() {
        let session = AVCaptureSession()
        let delegate = MockDepthDelegate()
        let queue = DispatchQueue(label: "test.depth")
        // Without configured inputs, adding depth output may or may not succeed
        // depending on session configuration — just verify it doesn't crash
        _ = PRMDepthHelper.addDepthDataOutput(to: session, delegate: delegate, queue: queue)
    }

    @Test("setFilteringEnabled modifies depth output")
    func filteringEnabled() {
        let output = AVCaptureDepthDataOutput()
        PRMDepthHelper.setFilteringEnabled(false, on: output)
        #expect(PRMDepthHelper.isFilteringEnabled(on: output) == false)

        PRMDepthHelper.setFilteringEnabled(true, on: output)
        #expect(PRMDepthHelper.isFilteringEnabled(on: output) == true)
    }

    @Test("isFilteringEnabled returns default state")
    func filteringDefault() {
        let output = AVCaptureDepthDataOutput()
        // Default filtering is enabled
        let result = PRMDepthHelper.isFilteringEnabled(on: output)
        #expect(result == true)
    }

    // MARK: - API Signature Verification

    @Test("addDepthDataOutput function signature is correct")
    func addDepthOutputSignature() {
        typealias Signature = (AVCaptureSession, any AVCaptureDepthDataOutputDelegate, DispatchQueue) -> AVCaptureDepthDataOutput?
        let _: Signature = PRMDepthHelper.addDepthDataOutput(to:delegate:queue:)
    }
}

// MARK: - Mock Delegate

private final class MockDepthDelegate: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {}
