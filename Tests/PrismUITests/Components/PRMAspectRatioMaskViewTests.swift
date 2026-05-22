import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMAspectRatioMaskViewTests {
    @Test
    func `Aspect ratio values are correct`() {
        let four_three: CGFloat = 4.0 / 3.0
        let sixteen_nine: CGFloat = 16.0 / 9.0
        #expect(abs((PRMAspectRatioMaskView.AspectRatio.ratio4x3.value ?? 0) - four_three) < 0.000001)
        #expect(abs((PRMAspectRatioMaskView.AspectRatio.ratio16x9.value ?? 0) - sixteen_nine) < 0.000001)
        #expect(PRMAspectRatioMaskView.AspectRatio.ratio1x1.value == 1.0)
        #expect(PRMAspectRatioMaskView.AspectRatio.unconstrained.value == nil)
    }

    @Test
    func `cropRect for unconstrained returns full bounds`() {
        let view = PRMAspectRatioMaskView()
        view.aspectRatio = .unconstrained
        let rect = view.cropRect(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test
    func `cropRect for 1x1 is centered square`() {
        let view = PRMAspectRatioMaskView()
        view.aspectRatio = .ratio1x1
        let rect = view.cropRect(in: CGRect(x: 0, y: 0, width: 100, height: 200))
        // Bounds are taller than wide; crop width = 100, crop height = 100.
        #expect(rect.size.width == 100)
        #expect(rect.size.height == 100)
        #expect(rect.minY == 50)
    }
}
