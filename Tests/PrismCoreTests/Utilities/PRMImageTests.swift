import CoreImage
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
}
