import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Turns the merged linear image into a Night photo: brighter than the scene looked, with
/// the highlights rolled off instead of clipped, and the remaining noise smoothed.
///
/// - **Gain:** brings the log-average luminance (the scene's "key") up to about 0.12 linear,
///   at most `min(3, 1 + log2(frames) / 2)` EV: every doubling of the frame count halves the
///   noise variance, which pays for half a stop.
/// - **Highlights:** `CIToneMapHeadroom` compresses what the gain pushed past white (street
///   lights, windows) into a shoulder.
/// - **Noise:** `CINoiseReduction`, stronger with more gain and weaker with more frames.
enum PRMNightTone {
    static let targetKey: Float = 0.12

    struct Stats: Equatable {
        /// Geometric mean of the luminance (floored at 1e-4), linear.
        var logAverage: Float
        /// The 99.5th percentile luminance, linear.
        var highlight: Float
    }

    // MARK: - Pure helpers

    static func stats(luminances: [Float]) -> Stats {
        let valid = luminances.filter(\.isFinite)
        guard !valid.isEmpty else { return Stats(logAverage: 0, highlight: 0) }
        let logSum = valid.reduce(Float(0)) { $0 + log(max($1, 1e-4)) }
        let sorted = valid.sorted()
        let index = min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.995))
        return Stats(logAverage: exp(logSum / Float(valid.count)), highlight: sorted[index])
    }

    static func gainEV(key: Float, frameCount: Int, targetKey: Float = targetKey) -> Float {
        guard key.isFinite, key > 0 else { return 0 }
        let cap = min(3, 1 + 0.5 * log2(Float(max(frameCount, 1))))
        return min(max(log2(targetKey / key), 0), cap)
    }

    /// `CINoiseReduction`'s noise level (its default is 0.02).
    static func noiseLevel(gainEV: Float, frameCount: Int) -> Float {
        let level = 0.01 * pow(2, gainEV) / Float(max(frameCount, 1)).squareRoot()
        return min(max(level, 0.005), 0.04)
    }

    /// The `CGImagePropertyOrientation` that turns an image by `degrees` clockwise (a
    /// connection's `videoRotationAngle`).
    static func orientation(forClockwiseDegrees degrees: CGFloat) -> CGImagePropertyOrientation {
        let normalized = ((Int(degrees.rounded()) % 360) + 360) % 360
        return switch normalized {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    // MARK: - Rendering

    /// Linear luminances of `image`, scaled to fit `maxDimension`.
    static func luminanceSamples(of image: CIImage, context: CIContext, maxDimension: CGFloat = 256) -> [Float] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return [] }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        let bounds = small.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return [] }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            small,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        var luminances = [Float]()
        luminances.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            luminances.append(0.2126 * pixels[index] + 0.7152 * pixels[index + 1] + 0.0722 * pixels[index + 2])
        }
        return luminances
    }

    /// The brightened, tone-mapped and denoised image, cropped to `linear`'s extent.
    static func render(_ linear: CIImage, gainEV: Float, highlight: Float, frameCount: Int) -> CIImage {
        let extent = linear.extent
        var image = linear.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gainEV])
        let headroom = max(1, highlight * pow(2, gainEV))
        if headroom > 1.01 {
            let toneMap = CIFilter.toneMapHeadroom()
            toneMap.inputImage = image
            toneMap.sourceHeadroom = headroom
            toneMap.targetHeadroom = 1
            image = toneMap.outputImage ?? image
        }
        image = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseLevel(gainEV: gainEV, frameCount: frameCount),
            "inputSharpness": 0.4,
        ])
        image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
        return image.cropped(to: extent)
    }

    /// `image` turned by `degrees` clockwise, then mirrored left to right when `mirrored`,
    /// with its origin back at zero.
    static func oriented(_ image: CIImage, clockwiseDegrees degrees: CGFloat, mirrored: Bool) -> CIImage {
        var result = image.oriented(orientation(forClockwiseDegrees: degrees))
        if mirrored {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        let extent = result.extent
        return result.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
