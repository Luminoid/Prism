import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    /// Result of a frame rate change.
    struct PRMFrameRateChange: Sendable, Equatable {
        /// The frame rate actually applied.
        public let appliedFPS: Float64
        /// Whether the active format was switched to accommodate the requested fps.
        public let formatChanged: Bool

        public init(appliedFPS: Float64, formatChanged: Bool) {
            self.appliedFPS = appliedFPS
            self.formatChanged = formatChanged
        }
    }

    /// Sets the frame rate, potentially switching format if the current one doesn't support
    /// the request.
    ///
    /// - Parameters:
    ///   - fps: Target frames per second.
    ///   - allowFormatChange: When `true` (default), the helper switches to a 1080p-class
    ///     format if the current format can't deliver the requested fps. The target is the
    ///     largest format whose width is ≤ 1920 — picking the highest-res available format
    ///     would push 4K@60 (or higher) through the preview/Metal pipeline every frame,
    ///     introducing visible motion latency. Callers that specifically want 4K@60 should
    ///     set `activeFormat` directly. When `false`, the call no-ops if the current
    ///     format can't deliver the rate.
    /// - Returns: A summary of what was actually applied.
    /// - Throws: If the device cannot be locked for configuration.
    @discardableResult
    func prm_setFrameRate(_ fps: Float64, allowFormatChange: Bool = true) throws -> PRMFrameRateChange? {
        guard fps > 0 else { return nil }
        let duration = CMTimeMake(value: 1, timescale: Int32(fps))

        let currentSupports = activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps && $0.maxFrameRate >= fps
        }

        if currentSupports {
            try lockForConfiguration()
            defer { unlockForConfiguration() }
            activeVideoMinFrameDuration = duration
            activeVideoMaxFrameDuration = duration
            return PRMFrameRateChange(appliedFPS: fps, formatChanged: false)
        }

        guard allowFormatChange else { return nil }

        // Format-selection policy depends on the requested fps:
        //
        // - Normal video (≤ 60 fps): target a 1080p-class format (largest with width
        //   ≤ 1920). 4K@60 on modern iPhones would push every frame through the
        //   preview/Metal pipeline at full resolution, killing motion latency.
        // - Slo-mo (≥ 120 fps): pick the *largest* slo-mo format available. These
        //   formats are already capped at 1080p or 720p on most devices (the sensor
        //   read time at 120/240 fps doesn't allow more), so "largest" doesn't risk
        //   the 4K overload, and a wider format gives the user the best field of
        //   view — same trade-off Apple Camera makes for its slo-mo mode.
        let preferLargest = fps >= 120
        let targetMaxPixels: Int32 = 1920 * 1080
        var bestSubHD: AVCaptureDevice.Format?
        var bestSubHDPixels: Int32 = 0
        var smallest: AVCaptureDevice.Format?
        var smallestPixels: Int32 = .max
        var largest: AVCaptureDevice.Format?
        var largestPixels: Int32 = 0
        for format in formats {
            let supports = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && $0.maxFrameRate >= fps
            }
            guard supports else { continue }
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
            if pixels > largestPixels {
                largest = format
                largestPixels = pixels
            }
        }

        let format: AVCaptureDevice.Format? = if preferLargest {
            largest ?? bestSubHD ?? smallest
        } else {
            bestSubHD ?? smallest
        }
        guard let format else { return nil }

        try lockForConfiguration()
        defer { unlockForConfiguration() }
        activeFormat = format
        activeVideoMinFrameDuration = duration
        activeVideoMaxFrameDuration = duration
        return PRMFrameRateChange(appliedFPS: fps, formatChanged: true)
    }

    /// Clears frame rate constraints, returning to the device's default.
    func prm_resetFrameRate() throws {
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        activeVideoMinFrameDuration = .invalid
        activeVideoMaxFrameDuration = .invalid
    }

    /// Current effective frame rate derived from `activeVideoMinFrameDuration`.
    /// `nil` if no custom rate is set.
    func prm_currentFrameRate() -> Float64? {
        let duration = activeVideoMinFrameDuration
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0, seconds.isFinite else { return nil }
        return 1.0 / seconds
    }

    /// Maximum supported fps across all formats.
    func prm_maxFrameRate() -> Float64 {
        var maxFPS: Float64 = 0
        for format in formats {
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
        }
        return maxFPS
    }

    /// Whether any format supports ≥120 fps.
    func prm_supportsSlowMotion() -> Bool {
        formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
        }
    }

    /// Whether any format supports the given fps.
    func prm_supports(framesPerSecond fps: Float64) -> Bool {
        formats.contains { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && $0.maxFrameRate >= fps
            }
        }
    }
}
