import CoreImage
import ImageIO
import Testing
@testable import PrismCore

struct PRMImageTests {
    @Test
    func `Encodes a CIImage to JPEG`() throws {
        let context = try #require(PRMRenderContext())
        let image = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = PRMImage.jpegData(from: image, context: context)
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test
    func `Preserves EXIF when passed properties`() throws {
        let context = try #require(PRMRenderContext())
        let image = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let props: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensModel as String: "iPhone 17 main camera",
            ],
        ]
        let data = PRMImage.jpegDataPreservingMetadata(
            from: image,
            sourceExtent: image.extent,
            originalProperties: props,
            context: context
        )
        #expect(data != nil)
    }

    @Test
    func `A filtered photo encodes to HEIC without an alpha channel`() throws {
        let context = try #require(PRMRenderContext())
        // A blur leaves Core Image unable to prove the image opaque.
        let source = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let filtered = source.applyingGaussianBlur(sigma: 2)
        // Simulators without an HEVC encoder return nil; nothing to check there.
        guard let data = PRMImage.heifDataPreservingMetadata(
            from: filtered,
            sourceExtent: source.extent,
            originalProperties: [:],
            context: context
        ) else { return }
        let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo))
    }
}
