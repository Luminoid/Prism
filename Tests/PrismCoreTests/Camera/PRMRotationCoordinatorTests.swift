import AVFoundation
import Testing
@testable import PrismCore

/// `PRMRotationCoordinator` wraps `AVCaptureDevice.RotationCoordinator`, which needs a real
/// device; these lock the public surface.
@MainActor
struct PRMRotationCoordinatorTests {
    @Test
    func `Public signatures compile`() {
        let preview: @MainActor (PRMRotationCoordinator) -> AsyncStream<CGFloat> = { $0.previewRotationAngles() }
        let capture: @MainActor (PRMRotationCoordinator) -> AsyncStream<CGFloat> = { $0.captureRotationAngles() }
        let currentCapture: @MainActor (PRMRotationCoordinator) -> CGFloat = { $0.currentCaptureRotationAngle }
        let currentPreview: @MainActor (PRMRotationCoordinator) -> CGFloat = { $0.currentPreviewRotationAngle }
        let frame: @MainActor (PRMRotationCoordinator, CGFloat) -> CGFloat = { $0.portraitFrameRotation(connectionAngle: $1) }
        _ = (preview, capture, currentCapture, currentPreview, frame)
    }

    @Test(arguments: [
        // Back cameras: upright at 90° in portrait, connection at its default 0°.
        (CGFloat(90), CGFloat(0), CGFloat(90)),
        // The Center Stage front camera (iPhone 17 and later): mounted in portrait, so upright
        // at 0°, but its connection defaults to 270° to look like older front cameras.
        (0, 270, 90),
        // A connection already rotated upright needs nothing more.
        (90, 90, 0),
        // Recent iPads' front camera defaults to 180°.
        (270, 180, 90),
        (0, 90, 270),
        (360, 0, 0),
    ])
    func `Frame rotation is what the connection hasn't applied`(upright: CGFloat, connection: CGFloat, expected: CGFloat) {
        #expect(PRMRotationCoordinator.frameRotation(uprightAngle: upright, connectionAngle: connection) == expected)
    }

    @Test(.enabled(if: OSAvailability.isIOS27))
    func `The iOS 27 static angle signature compiles`() {
        guard #available(iOS 27.0, *) else { return }
        let relative: @MainActor (PRMRotationCoordinator, AVCaptureVideoOrientation) -> CGFloat = { $0.videoRotationAngle(relativeTo: $1) }
        _ = relative
    }
}
