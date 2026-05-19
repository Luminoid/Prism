import CoreMedia
import Testing
@testable import PrismCore

struct PRMBufferPoolAllocatorTests {
    @Test
    func `Allocates pool for 32BGRA format`() throws {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 256, height: 256,
            extensions: nil,
            formatDescriptionOut: &format
        )
        let formatDescription = try #require(format)
        let allocation = PRMBufferPoolAllocator.allocate(
            with: formatDescription,
            retainedBufferCountHint: 3
        )
        #expect(allocation != nil)
    }

    @Test
    func `Rejects non-32BGRA format`() throws {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 256, height: 256,
            extensions: nil,
            formatDescriptionOut: &format
        )
        let formatDescription = try #require(format)
        let allocation = PRMBufferPoolAllocator.allocate(
            with: formatDescription,
            retainedBufferCountHint: 3
        )
        #expect(allocation == nil)
    }
}
