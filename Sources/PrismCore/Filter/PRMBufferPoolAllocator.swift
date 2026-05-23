import CoreMedia
import CoreVideo

/// Allocates `CVPixelBufferPool` instances for the filter pipeline.
public enum PRMBufferPoolAllocator: Sendable {
    /// Result of a successful pool allocation.
    public struct Allocation: @unchecked Sendable {
        public let bufferPool: CVPixelBufferPool
        public let colorSpace: CGColorSpace
        public let formatDescription: CMFormatDescription
    }

    /// Allocates an output pool matching the given input format (must be 32BGRA).
    public static func allocate(
        with inputFormatDescription: CMFormatDescription,
        retainedBufferCountHint: Int
    ) -> Allocation? {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
        guard mediaSubType == kCVPixelFormatType_32BGRA else {
            PRMLogger.filter.error("Invalid input pixel buffer type: \(mediaSubType)")
            return nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        var pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: UInt(mediaSubType),
            kCVPixelBufferWidthKey as String: Int(dimensions.width),
            kCVPixelBufferHeightKey as String: Int(dimensions.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let colorSpace = extractColorSpace(
            from: inputFormatDescription,
            pixelBufferAttributes: &pixelBufferAttributes
        )

        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: retainedBufferCountHint,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as NSDictionary?,
            pixelBufferAttributes as NSDictionary?,
            &pool
        )

        guard let pool else {
            PRMLogger.filter.error("Failed to create pixel buffer pool")
            return nil
        }

        preallocate(pool: pool, threshold: retainedBufferCountHint)

        guard let outputFormat = deriveFormat(from: pool, threshold: retainedBufferCountHint) else {
            PRMLogger.filter.error("Failed to derive output format description")
            return nil
        }

        return Allocation(bufferPool: pool, colorSpace: colorSpace, formatDescription: outputFormat)
    }

    // MARK: - Private

    private static func extractColorSpace(
        from formatDescription: CMFormatDescription,
        pixelBufferAttributes: inout [String: Any]
    ) -> CGColorSpace {
        var colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as Dictionary?
        else {
            // No extensions at all — most camera formats DO carry color primaries,
            // so this is unusual. Log so a missing color-space mismatch on a P3 / Rec.2020
            // capture (color shifts on encode) doesn't surface only as a "looks wrong"
            // user report.
            PRMLogger.filter.notice(
                "CMFormatDescription has no extensions — falling back to deviceRGB color space"
            )
            return colorSpace
        }

        let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey]
        if let colorPrimaries {
            var properties: [String: AnyObject] = [
                kCVImageBufferColorPrimariesKey as String: colorPrimaries,
            ]
            if let ycbcr = extensions[kCVImageBufferYCbCrMatrixKey] {
                properties[kCVImageBufferYCbCrMatrixKey as String] = ycbcr
            }
            if let transferFn = extensions[kCVImageBufferTransferFunctionKey] {
                properties[kCVImageBufferTransferFunctionKey as String] = transferFn
            }
            pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = properties
        }

        // CoreVideo stores the color space as a CGColorSpace CFType under this key. Swift
        // bridges CGColorSpace via `as` unconditionally (the cast always succeeds because the
        // CF bridge is checked at runtime, hence the compiler's "downcast to CoreFoundation
        // type will always succeed" warning). We still guard with `CFGetTypeID` so a malformed
        // format description (wrong CFType under this key) falls through to deviceRGB instead
        // of crashing somewhere downstream when the wrong type is used as a color space.
        if let cvColorSpace = extensions[kCVImageBufferCGColorSpaceKey] {
            if CFGetTypeID(cvColorSpace as CFTypeRef) == CGColorSpace.typeID {
                colorSpace = cvColorSpace as! CGColorSpace // swiftlint:disable:this force_cast
            } else {
                PRMLogger.filter.error(
                    "kCVImageBufferCGColorSpaceKey present but is not a CGColorSpace (typeID mismatch); falling back to deviceRGB"
                )
            }
        } else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String),
                  let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
            colorSpace = displayP3
        } else if colorPrimaries != nil {
            // Format description carried color primaries but neither a CGColorSpace
            // payload nor a recognized primaries match. We propagated the primaries +
            // YCbCr matrix + transfer function via `kCVBufferPropagatedAttachmentsKey`
            // so CoreVideo can still render the buffer, but the CIContext encode path
            // will use deviceRGB — which on a Rec.2020 / extended-range capture causes
            // visible color shifts. Surface this at .notice so unexpected color drift
            // has a single log line to grep for.
            PRMLogger.filter.notice(
                "Camera format has color primaries but no CGColorSpace payload; falling back to deviceRGB (may shift colors on encode)"
            )
        }

        return colorSpace
    }

    /// Walks the pool up to its `kCVPixelBufferPoolAllocationThresholdKey` ceiling by
    /// creating `threshold` buffers in succession, then lets them release as the local
    /// array goes out of scope. The point isn't to keep the buffers — it's to force the
    /// pool to internally grow to its working set size at allocator-construction time,
    /// so the first real frame doesn't pay the lazy-growth cost.
    private static func preallocate(pool: CVPixelBufferPool, threshold: Int) {
        var buffers: [CVPixelBuffer] = []
        buffers.reserveCapacity(threshold)
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: threshold] as NSDictionary

        var result: CVReturn = kCVReturnSuccess
        while result == kCVReturnSuccess {
            var buffer: CVPixelBuffer?
            result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pool, aux, &buffer
            )
            if let buffer { buffers.append(buffer) }
        }
        // `buffers` deinit at the end of scope drops every ref; the pool keeps the
        // internal capacity it just grew to. No explicit `removeAll()` needed.
    }

    private static func deriveFormat(
        from pool: CVPixelBufferPool,
        threshold: Int
    ) -> CMFormatDescription? {
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: threshold] as NSDictionary
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, aux, &buffer
        )
        guard let buffer else { return nil }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        return format
    }
}
