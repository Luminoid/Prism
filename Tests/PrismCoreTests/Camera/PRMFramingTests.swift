import AVFoundation
import Testing
@testable import PrismCore

struct PRMFramingTests {
    @Test
    func `Aspect ratios report orientation`() {
        #expect(PRMAspectRatio.ratio9x16.isPortrait)
        #expect(PRMAspectRatio.ratio3x4.isPortrait)
        #expect(!PRMAspectRatio.ratio16x9.isPortrait)
        #expect(!PRMAspectRatio.ratio1x1.isPortrait)
        #expect(PRMAspectRatio.ratio4x3.widthOverHeight == 4.0 / 3.0)
    }

    @Test(.enabled(if: OSAvailability.isIOS26))
    func `Aspect ratios round-trip through AVFoundation`() {
        guard #available(iOS 26.0, *) else { return }
        for ratio in PRMAspectRatio.allCases {
            #expect(PRMAspectRatio(ratio.avAspectRatio) == ratio)
        }
    }

    @Test
    func `Video dimensions treat a zero side as empty`() {
        #expect(PRMVideoDimensions(width: 0, height: 1080).isEmpty)
        #expect(!PRMVideoDimensions(width: 1920, height: 1080).isEmpty)
        #expect(PRMVideoDimensions(CMVideoDimensions(width: 4032, height: 3024)) == PRMVideoDimensions(width: 4032, height: 3024))
    }
}
