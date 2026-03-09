import AVFoundation
import CoreMedia
import os

/// Provides frame rate control utilities for `AVCaptureDevice`.
///
/// Supports setting custom frame rates for slow-motion and time-lapse,
/// and querying supported frame rate ranges.
///
/// ```swift
/// try PRMFrameRateHelper.setFrameRate(120, on: device)
/// PRMFrameRateHelper.supportsSlowMotion(on: device) // true for 120+ fps
/// ```
public enum PRMFrameRateHelper: Sendable {
    // MARK: - Types

    /// A range of supported frame rates for a device format.
    public struct FrameRateRange: Sendable {
        /// The minimum frame rate in this range.
        public let minFrameRate: Float64
        /// The maximum frame rate in this range.
        public let maxFrameRate: Float64

        public init(minFrameRate: Float64, maxFrameRate: Float64) {
            self.minFrameRate = minFrameRate
            self.maxFrameRate = maxFrameRate
        }
    }

    // MARK: - Control

    /// Sets the frame rate on the device by adjusting `activeVideoMinFrameDuration`
    /// and `activeVideoMaxFrameDuration`.
    ///
    /// This selects the best matching format for the requested frame rate.
    /// - Parameters:
    ///   - fps: The desired frames per second.
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setFrameRate(_ fps: Float64, on device: AVCaptureDevice) throws {
        guard fps > 0 else {
            PRMLogger.session.warning("Invalid frame rate: \(fps)")
            return
        }

        let duration = CMTimeMake(value: 1, timescale: Int32(fps))

        // If the current format already supports the requested FPS, just set the duration
        // without changing the format (avoids resolution/quality disruption).
        let currentSupports = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps && $0.maxFrameRate >= fps
        }

        if currentSupports {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            return
        }

        // Find the format with the highest resolution that supports the requested FPS.
        var bestFormat: AVCaptureDevice.Format?
        var bestPixels: Int32 = 0

        for format in device.formats {
            let supports = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && $0.maxFrameRate >= fps
            }
            guard supports else { continue }

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = dims.width * dims.height
            if pixels > bestPixels {
                bestFormat = format
                bestPixels = pixels
            }
        }

        guard let format = bestFormat else {
            PRMLogger.session.warning("No format supports \(fps) fps")
            return
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    /// Resets the frame rate to the device's default by clearing min/max duration constraints.
    ///
    /// - Parameter device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func resetToDefaultFrameRate(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = .invalid
        device.activeVideoMaxFrameDuration = .invalid
        device.unlockForConfiguration()
    }

    // MARK: - Queries

    /// Returns the current effective frame rate derived from `activeVideoMinFrameDuration`.
    ///
    /// Returns `nil` if no custom frame rate is set (duration is invalid or zero).
    public static func currentFrameRate(for device: AVCaptureDevice) -> Float64? {
        let duration = device.activeVideoMinFrameDuration
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0, seconds.isFinite else { return nil }
        return 1.0 / seconds
    }

    /// Returns all supported frame rate ranges for the device's active format.
    public static func supportedFrameRateRanges(
        for device: AVCaptureDevice,
    ) -> [FrameRateRange] {
        device.activeFormat.videoSupportedFrameRateRanges.map {
            FrameRateRange(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
        }
    }

    /// Returns all supported frame rate ranges across all device formats.
    public static func allSupportedFrameRateRanges(
        for device: AVCaptureDevice,
    ) -> [FrameRateRange] {
        var ranges: [FrameRateRange] = []
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                ranges.append(FrameRateRange(minFrameRate: range.minFrameRate, maxFrameRate: range.maxFrameRate))
            }
        }
        return ranges
    }

    /// Whether the device supports slow-motion (120+ fps) in any format.
    public static func supportsSlowMotion(on device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
        }
    }

    /// Whether the device supports the given frame rate in any format.
    public static func supportsFrameRate(_ fps: Float64, on device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && $0.maxFrameRate >= fps
            }
        }
    }

    /// The maximum supported frame rate across all formats.
    public static func maxSupportedFrameRate(for device: AVCaptureDevice) -> Float64 {
        var maxFPS: Float64 = 0
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                maxFPS = max(maxFPS, range.maxFrameRate)
            }
        }
        return maxFPS
    }
}
