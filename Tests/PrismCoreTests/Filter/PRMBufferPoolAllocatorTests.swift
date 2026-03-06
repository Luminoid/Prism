import CoreMedia
import CoreVideo
import Testing
@testable import PrismCore

// MARK: - PRMBufferPoolAllocatorTests

@Suite("PRMBufferPoolAllocator")
struct PRMBufferPoolAllocatorTests {
    // MARK: - Helpers

    /// Creates a 32BGRA format description for testing.
    private func makeBGRAFormatDescription(width: Int32 = 1920, height: Int32 = 1080) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription,
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// Creates a non-BGRA format description for testing rejection.
    private func make420YpCbCr8FormatDescription() -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &formatDescription,
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    // MARK: - Allocation

    @Test("Allocates buffer pool from valid 32BGRA format")
    func allocateFromValidFormat() throws {
        let format = try #require(makeBGRAFormatDescription())
        let result = PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: format,
            retainedBufferCountHint: 3,
        )
        #expect(result != nil)
    }

    @Test("Allocation result contains valid components")
    func allocationResultComponents() throws {
        let format = try #require(makeBGRAFormatDescription())
        let result = try #require(PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: format,
            retainedBufferCountHint: 3,
        ))

        #expect(result.formatDescription != nil)
        // Color space should be valid
        #expect(result.colorSpace.numberOfComponents > 0)
    }

    @Test("Rejects non-32BGRA format")
    func rejectsInvalidFormat() throws {
        let format = try #require(make420YpCbCr8FormatDescription())
        let result = PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: format,
            retainedBufferCountHint: 3,
        )
        #expect(result == nil)
    }

    @Test("Pool creates pixel buffers")
    func poolCreatesBuffers() throws {
        let format = try #require(makeBGRAFormatDescription(width: 64, height: 64))
        let result = try #require(PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: format,
            retainedBufferCountHint: 3,
        ))

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, result.bufferPool, &pixelBuffer)
        #expect(status == kCVReturnSuccess)
        #expect(pixelBuffer != nil)
    }

    @Test("Output format matches input dimensions")
    func outputMatchesInputDimensions() throws {
        let format = try #require(makeBGRAFormatDescription(width: 640, height: 480))
        let result = try #require(PRMBufferPoolAllocator.allocateOutputBufferPool(
            with: format,
            retainedBufferCountHint: 3,
        ))

        let outputDimensions = CMVideoFormatDescriptionGetDimensions(result.formatDescription)
        #expect(outputDimensions.width == 640)
        #expect(outputDimensions.height == 480)
    }
}
