import AVFoundation

public extension AVCaptureDevice {
    /// Whether the device's active format currently exposes any depth data stream.
    /// When `false`, photo captures requesting depth will deliver an `AVDepthData`
    /// whose `depthDataMap` is internally null (Apple's runtime emits
    /// `-[CIImage initWithCVPixelBuffer:options:] failed because the buffer is nil`
    /// when you wrap that map in a CIImage), so callers should switch to a
    /// depth-supporting format via ``prm_enableDepthFormat()`` first.
    func prm_isActiveFormatDepthCapable() -> Bool {
        !activeFormat.supportedDepthDataFormats.isEmpty
    }

    /// Picks a depth-capable format + depth data format and applies both. AVFoundation
    /// requires `activeFormat` *and* `activeDepthDataFormat` to be set before depth
    /// ancillary data is actually populated on photo captures — an "active format with
    /// supported depth formats" alone is not enough; the depth format must be selected
    /// out of the supported set and assigned.
    ///
    /// When the active format already supports depth, only `activeDepthDataFormat` is
    /// touched (no resolution change). When it doesn't, the active format is switched
    /// to a 1080p-class depth-capable format — picking 4K would push depth-aware
    /// previews through Metal at full resolution every frame, which kills the preview
    /// frame rate on Pro models.
    ///
    /// - Returns: `true` if a depth format is now active, `false` if the device has
    ///   no depth-capable formats.
    /// - Throws: If the device cannot be locked for configuration.
    @discardableResult
    func prm_enableDepthFormat() throws -> Bool {
        // Pick the target format up front so the lock-for-configuration block is
        // strictly the AV-mutating section.
        let targetFormat: AVCaptureDevice.Format
        let targetDepthFormat: AVCaptureDevice.Format
        if prm_isActiveFormatDepthCapable() {
            // Active format already exposes depth. Keep it, but pick a depth format if
            // none is currently active.
            targetFormat = activeFormat
            if let depthFormat = activeDepthDataFormat {
                targetDepthFormat = depthFormat
            } else if let depthFormat = activeFormat.supportedDepthDataFormats.first {
                targetDepthFormat = depthFormat
            } else {
                return false
            }
        } else {
            // Active format doesn't support depth — pick a depth-capable one. Prefer
            // a 1080p-class option (largest format ≤ 1920px wide); fall back to the
            // smallest depth-capable format if no sub-4K option exists.
            let targetMaxPixels: Int32 = 1920 * 1080
            var bestSubHD: AVCaptureDevice.Format?
            var bestSubHDPixels: Int32 = 0
            var smallest: AVCaptureDevice.Format?
            var smallestPixels: Int32 = .max
            for format in formats {
                guard !format.supportedDepthDataFormats.isEmpty else { continue }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let pixels = dims.width * dims.height
                if pixels <= targetMaxPixels, pixels > bestSubHDPixels {
                    bestSubHD = format
                    bestSubHDPixels = pixels
                }
                if pixels < smallestPixels {
                    smallest = format
                    smallestPixels = pixels
                }
            }
            guard let format = bestSubHD ?? smallest,
                  let depthFormat = format.supportedDepthDataFormats.first
            else { return false }
            targetFormat = format
            targetDepthFormat = depthFormat
        }

        try lockForConfiguration()
        defer { unlockForConfiguration() }

        // Geometric distortion correction is enabled by default on multi-camera
        // virtual devices (builtInTripleCamera / builtInDualCamera). When GDC is on,
        // AVFoundation suppresses depth + camera calibration data delivery because
        // the corrected frames no longer match the depth maps' coordinate space.
        // The symptom matches the iPhone Pro reports exactly: depth ancillaries
        // arrive but `depthDataMap` is internally null, with no error surfaced.
        // Disable GDC before applying the depth format. See Apple Developer Forum
        // thread 131829 (Dual delivery with empty calibration data).
        #if !os(macOS)
            if isGeometricDistortionCorrectionSupported, isGeometricDistortionCorrectionEnabled {
                isGeometricDistortionCorrectionEnabled = false
            }
        #endif

        if activeFormat !== targetFormat {
            activeFormat = targetFormat
        }
        if activeDepthDataFormat !== targetDepthFormat {
            activeDepthDataFormat = targetDepthFormat
        }
        return true
    }
}
