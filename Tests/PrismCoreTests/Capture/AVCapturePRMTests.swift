import AVFoundation
import Testing
@testable import PrismCore

// MARK: - PRMVideoRotationAngleTests

@Suite("PRMVideoRotationAngle")
struct PRMVideoRotationAngleTests {
    @Test("Portrait is 90 degrees")
    func portrait() {
        #expect(PRMVideoRotationAngle.portrait == 90)
    }

    @Test("Portrait upside down is 270 degrees")
    func portraitUpsideDown() {
        #expect(PRMVideoRotationAngle.portraitUpsideDown == 270)
    }

    @Test("Landscape right is 0 degrees")
    func landscapeRight() {
        #expect(PRMVideoRotationAngle.landscapeRight == 0)
    }

    @Test("Landscape left is 180 degrees")
    func landscapeLeft() {
        #expect(PRMVideoRotationAngle.landscapeLeft == 180)
    }
}

// MARK: - Device Orientation Rotation Angle Tests

#if canImport(UIKit)
    import UIKit

    @Suite("UIDeviceOrientation Rotation Angle")
    struct DeviceOrientationRotationAngleTests {
        @Test("Portrait maps to 90 degrees")
        func portraitMapping() {
            #expect(UIDeviceOrientation.portrait.prm_videoRotationAngle == 90)
        }

        @Test("Portrait upside down maps to 270 degrees")
        func portraitUpsideDownMapping() {
            #expect(UIDeviceOrientation.portraitUpsideDown.prm_videoRotationAngle == 270)
        }

        @Test("Landscape left maps to 0 degrees (swapped)")
        func landscapeLeftMapping() {
            #expect(UIDeviceOrientation.landscapeLeft.prm_videoRotationAngle == 0)
        }

        @Test("Landscape right maps to 180 degrees (swapped)")
        func landscapeRightMapping() {
            #expect(UIDeviceOrientation.landscapeRight.prm_videoRotationAngle == 180)
        }

        @Test("Face up returns nil")
        func faceUpNil() {
            #expect(UIDeviceOrientation.faceUp.prm_videoRotationAngle == nil)
        }

        @Test("Face down returns nil")
        func faceDownNil() {
            #expect(UIDeviceOrientation.faceDown.prm_videoRotationAngle == nil)
        }

        @Test("Unknown returns nil")
        func unknownNil() {
            #expect(UIDeviceOrientation.unknown.prm_videoRotationAngle == nil)
        }
    }

    // MARK: - Interface Orientation Rotation Angle Tests

    @Suite("UIInterfaceOrientation Rotation Angle")
    struct InterfaceOrientationRotationAngleTests {
        @Test("Portrait maps to 90 degrees")
        func interfacePortrait() {
            #expect(UIInterfaceOrientation.portrait.prm_videoRotationAngle == 90)
        }

        @Test("Landscape left maps to 180 degrees")
        func interfaceLandscapeLeft() {
            #expect(UIInterfaceOrientation.landscapeLeft.prm_videoRotationAngle == 180)
        }

        @Test("Landscape right maps to 0 degrees")
        func interfaceLandscapeRight() {
            #expect(UIInterfaceOrientation.landscapeRight.prm_videoRotationAngle == 0)
        }

        @Test("Unknown returns nil")
        func interfaceUnknown() {
            #expect(UIInterfaceOrientation.unknown.prm_videoRotationAngle == nil)
        }
    }
#endif
