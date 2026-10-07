import AVFoundation
import Testing
@testable import PrismCore

/// `AVCapturePhotoOutput+Readiness.swift`: the shared readiness check and the
/// "largest landscape photo dimensions" pick behind the ceiling heal.
struct AVCapturePhotoOutputReadinessTests {
    @Test
    func `A bare output isn't ready`() {
        let readiness = AVCapturePhotoOutput().prm_readiness
        #expect(!readiness.hasConnection)
        #expect(!readiness.isReady)
        #expect(readiness.summary.contains("connection=none"))
    }

    @Test
    func `A bare output has nothing to heal`() {
        #expect(AVCapturePhotoOutput().prm_healMaxPhotoDimensionsIfNeeded() == nil)
    }

    @Test
    func `The largest landscape entry wins by area`() {
        let dims = [
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 3024, height: 4032), // portrait video entry, ignored
            CMVideoDimensions(width: 8064, height: 6048),
            CMVideoDimensions(width: 1920, height: 1080),
        ]
        let largest = AVCaptureDevice.Format.prm_largestLandscape(dims)
        #expect(largest?.width == 8064)
        #expect(largest?.height == 6048)
        #expect(AVCaptureDevice.Format.prm_largestLandscape([CMVideoDimensions(width: 3024, height: 4032)]) == nil)
    }
}
