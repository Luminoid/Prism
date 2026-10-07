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
        guard fps.isFinite, fps > 0 else { return nil }

        if let range = Self.prm_frameRateRange(containing: fps, in: activeFormat) {
            let duration = Self.prm_frameDuration(forFPS: fps, min: range.minFrameDuration, max: range.maxFrameDuration)
            try prm_withConfigurationLock {
                activeVideoMinFrameDuration = duration
                activeVideoMaxFrameDuration = duration
            }
            return PRMFrameRateChange(appliedFPS: Self.prm_frameRate(of: duration), formatChanged: false)
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
        let format = Self.prm_hdClassFormat(from: formats, preferLargest: fps >= 120) { format in
            Self.prm_frameRateRange(containing: fps, in: format) != nil
        }
        guard let format, let range = Self.prm_frameRateRange(containing: fps, in: format) else { return nil }
        let duration = Self.prm_frameDuration(forFPS: fps, min: range.minFrameDuration, max: range.maxFrameDuration)

        try prm_withConfigurationLock {
            activeFormat = format
            activeVideoMinFrameDuration = duration
            activeVideoMaxFrameDuration = duration
        }
        return PRMFrameRateChange(appliedFPS: Self.prm_frameRate(of: duration), formatChanged: true)
    }

    /// Clears frame rate constraints, returning to the device's default.
    func prm_resetFrameRate() throws {
        try prm_withConfigurationLock {
            activeVideoMinFrameDuration = .invalid
            activeVideoMaxFrameDuration = .invalid
        }
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

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// The format's frame-rate range that contains `fps`, if any.
    static func prm_frameRateRange(containing fps: Float64, in format: AVCaptureDevice.Format) -> AVFrameRateRange? {
        format.videoSupportedFrameRateRanges.first { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
    }

    /// Frame duration for `fps`, kept inside a range's `[min, max]` frame durations. Rates
    /// at a range's ends use the range's own durations, so fractional rates such as 29.97
    /// (1001/30000 s) come out exact; other rates use a 1/60000 s timescale. Pure, so it's
    /// unit-testable.
    static func prm_frameDuration(forFPS fps: Float64, min lower: CMTime, max upper: CMTime) -> CMTime {
        let shortest = CMTimeGetSeconds(lower)
        let longest = CMTimeGetSeconds(upper)
        if shortest > 0, abs(1 / shortest - fps) < 0.01 { return lower }
        if longest > 0, abs(1 / longest - fps) < 0.01 { return upper }
        let duration = CMTimeMakeWithSeconds(1 / fps, preferredTimescale: 60000)
        if lower.isNumeric, CMTimeCompare(duration, lower) < 0 { return lower }
        if upper.isNumeric, CMTimeCompare(duration, upper) > 0 { return upper }
        return duration
    }

    /// Frames per second for a frame duration (`0` when the duration isn't positive).
    static func prm_frameRate(of duration: CMTime) -> Float64 {
        let seconds = CMTimeGetSeconds(duration)
        return seconds > 0 && seconds.isFinite ? 1 / seconds : 0
    }

    /// Picks a format for a frame-rate or depth switch: among formats matching `predicate`,
    /// the largest at or below 1920×1080 pixels (so the preview doesn't push 4K through
    /// Metal every frame), or the smallest when none is that small. With `preferLargest`
    /// (slow motion, whose formats are already capped at 1080p or 720p) the largest match
    /// wins outright.
    static func prm_hdClassFormat(
        from formats: [AVCaptureDevice.Format],
        preferLargest: Bool = false,
        where predicate: (AVCaptureDevice.Format) -> Bool
    ) -> AVCaptureDevice.Format? {
        let targetMaxPixels: Int64 = 1920 * 1080
        var bestSubHD: (format: AVCaptureDevice.Format, pixels: Int64)?
        var smallest: (format: AVCaptureDevice.Format, pixels: Int64)?
        var largest: (format: AVCaptureDevice.Format, pixels: Int64)?
        for format in formats where predicate(format) {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int64(dims.width) * Int64(dims.height)
            if pixels <= targetMaxPixels, pixels > (bestSubHD?.pixels ?? 0) {
                bestSubHD = (format, pixels)
            }
            if pixels < (smallest?.pixels ?? .max) {
                smallest = (format, pixels)
            }
            if pixels > (largest?.pixels ?? 0) {
                largest = (format, pixels)
            }
        }
        if preferLargest {
            return (largest ?? bestSubHD ?? smallest)?.format
        }
        return (bestSubHD ?? smallest)?.format
    }
}
