import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
@testable import PrismCore

/// Synthetic frames for the Night tests: IOSurface-backed BGRA buffers, a textured image for
/// registration, and readers for the merged half-float output.
enum NightTestImages {
    /// An IOSurface-backed, Metal-compatible BGRA buffer filled by `pixel(x, y)` (RGB, 0...255),
    /// tagged with the sRGB transfer function.
    static func bgraBuffer(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        guard let buffer = PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let (red, green, blue) = pixel(x, y)
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    /// Renders `image` (its extent from the origin) into a new BGRA buffer, raw values.
    static func render(_ image: CIImage, width: Int, height: Int, context: CIContext) -> CVPixelBuffer? {
        guard let buffer = PRMNightMerger.makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else {
            return nil
        }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return buffer
    }

    /// Blurred, contrast-stretched noise: detail at every scale and no repetition, which image
    /// registration needs (at its natural low contrast Vision misjudges the shift).
    static func texture(width: Int, height: Int) -> CIImage {
        (CIFilter.randomGenerator().outputImage ?? CIImage.empty())
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 4])
            .applyingGaussianBlur(sigma: 2)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Reads one RGBA pixel of a `64RGBAHalf` buffer (row 0 at the top).
    static func halfPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> SIMD4<Float> {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .zero }
        let row = (base + y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt16.self)
        let pixel = row + x * 4
        return SIMD4(
            Float(Float16(bitPattern: pixel[0])),
            Float(Float16(bitPattern: pixel[1])),
            Float(Float16(bitPattern: pixel[2])),
            Float(Float16(bitPattern: pixel[3]))
        )
    }

    /// The sRGB decode the merge shader applies.
    static func srgbToLinear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// A ready sample buffer around `pixelBuffer` with an optional `{Exif}` attachment.
    static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, exif: [String: Any]? = nil) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
        guard let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        if let sample, let exif {
            CMSetAttachment(sample, key: "{Exif}" as CFString, value: exif as CFDictionary, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sample
    }
}

/// A deterministic random number generator for repeatable noise.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
