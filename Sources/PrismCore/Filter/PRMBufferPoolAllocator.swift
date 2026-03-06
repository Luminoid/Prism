import CoreMedia
import CoreVideo
import os

/// Allocates and manages `CVPixelBufferPool` instances for the filter pipeline.
///
/// Extracted from AnimalVision's free-function approach into static methods
/// for better namespacing and discoverability.
public enum PRMBufferPoolAllocator: Sendable {
    /// The result of a successful buffer pool allocation.
    public struct AllocationResult: @unchecked Sendable {
        /// The allocated pixel buffer pool.
        public let bufferPool: CVPixelBufferPool
        /// The color space derived from the input format.
        public let colorSpace: CGColorSpace
        /// The format description of buffers created by this pool.
        public let formatDescription: CMFormatDescription
    }

    /// Allocates an output buffer pool matching the given input format.
    ///
    /// - Parameters:
    ///   - inputFormatDescription: The format of incoming pixel buffers (must be 32BGRA).
    ///   - retainedBufferCountHint: The minimum number of buffers to keep in the pool.
    /// - Returns: An `AllocationResult`, or `nil` if allocation fails.
    public static func allocateOutputBufferPool(
        with inputFormatDescription: CMFormatDescription,
        retainedBufferCountHint: Int,
    ) -> AllocationResult? {
        let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
        guard inputMediaSubType == kCVPixelFormatType_32BGRA else {
            PRMLogger.filter.error("Invalid input pixel buffer type: \(inputMediaSubType)")
            return nil
        }

        let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        var pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
            kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
            kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        // Extract color space from input format description
        let cgColorSpace = extractColorSpace(
            from: inputFormatDescription,
            pixelBufferAttributes: &pixelBufferAttributes,
        )

        // Create the pool
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: retainedBufferCountHint]
        var cvPixelBufferPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as NSDictionary?,
            pixelBufferAttributes as NSDictionary?,
            &cvPixelBufferPool,
        )

        guard let pixelBufferPool = cvPixelBufferPool else {
            PRMLogger.filter.error("Failed to create pixel buffer pool")
            return nil
        }

        preallocateBuffers(pool: pixelBufferPool, allocationThreshold: retainedBufferCountHint)

        // Derive output format description from the pool
        guard let outputFormatDescription = outputFormatDescription(
            from: pixelBufferPool,
            retainedBufferCountHint: retainedBufferCountHint,
        ) else {
            PRMLogger.filter.error("Failed to derive output format description")
            return nil
        }

        return AllocationResult(
            bufferPool: pixelBufferPool,
            colorSpace: cgColorSpace,
            formatDescription: outputFormatDescription,
        )
    }

    // MARK: - Private

    private static func extractColorSpace(
        from formatDescription: CMFormatDescription,
        pixelBufferAttributes: inout [String: Any],
    ) -> CGColorSpace {
        var cgColorSpace = CGColorSpaceCreateDeviceRGB()

        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as Dictionary? else {
            return cgColorSpace
        }

        let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey]

        if let colorPrimaries {
            var colorSpaceProperties: [String: AnyObject] = [
                kCVImageBufferColorPrimariesKey as String: colorPrimaries,
            ]
            if let yCbCrMatrix = extensions[kCVImageBufferYCbCrMatrixKey] {
                colorSpaceProperties[kCVImageBufferYCbCrMatrixKey as String] = yCbCrMatrix
            }
            if let transferFunction = extensions[kCVImageBufferTransferFunctionKey] {
                colorSpaceProperties[kCVImageBufferTransferFunctionKey as String] = transferFunction
            }
            pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
        }

        if let cvColorspace = extensions[kCVImageBufferCGColorSpaceKey] {
            // CGColorSpace is a CFType; bridge via CFTypeRef
            cgColorSpace = (cvColorspace as! CGColorSpace)  // swiftlint:disable:this force_cast
        } else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String),
                  let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
            cgColorSpace = displayP3
        }

        return cgColorSpace
    }

    private static func preallocateBuffers(pool: CVPixelBufferPool, allocationThreshold: Int) {
        var pixelBuffers: [CVPixelBuffer] = []
        let auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold,
        ] as NSDictionary

        var error: CVReturn = kCVReturnSuccess
        while error == kCVReturnSuccess {
            var pixelBuffer: CVPixelBuffer?
            error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxAttributes,
                &pixelBuffer,
            )
            if let pixelBuffer {
                pixelBuffers.append(pixelBuffer)
            }
        }
        pixelBuffers.removeAll()
    }

    private static func outputFormatDescription(
        from pool: CVPixelBufferPool,
        retainedBufferCountHint: Int,
    ) -> CMFormatDescription? {
        let auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: retainedBufferCountHint,
        ] as NSDictionary

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes,
            &pixelBuffer,
        )

        guard let pixelBuffer else { return nil }

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription,
        )
        return formatDescription
    }
}
