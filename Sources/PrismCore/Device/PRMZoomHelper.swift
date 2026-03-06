import AVFoundation
import os

/// Provides zoom control utilities for `AVCaptureDevice`.
///
/// All methods that modify the device require the caller to hold `lockForConfiguration()`,
/// or use the throwing variants that handle locking internally.
///
/// ```swift
/// try PRMZoomHelper.setZoomFactor(2.0, on: device)
/// PRMZoomHelper.minZoomFactor(for: device) // 1.0
/// ```
public enum PRMZoomHelper: Sendable {
    // MARK: - Zoom Factor

    /// Sets the video zoom factor on the device.
    ///
    /// The factor is clamped to the device's supported range.
    /// - Parameters:
    ///   - factor: The desired zoom factor.
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func setZoomFactor(_ factor: CGFloat, on device: AVCaptureDevice) throws {
        let clamped = clampedZoomFactor(factor, for: device)
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
    }

    /// Begins a smooth zoom ramp to the target factor at the given rate.
    ///
    /// - Parameters:
    ///   - factor: The target zoom factor (clamped to device range).
    ///   - rate: The zoom rate — `pow(2, rate * time)`. A rate of 1.0 doubles magnification per second.
    ///   - device: The capture device to configure.
    /// - Throws: If the device cannot be locked for configuration.
    public static func rampZoom(
        to factor: CGFloat,
        withRate rate: Float,
        on device: AVCaptureDevice,
    ) throws {
        let clamped = clampedZoomFactor(factor, for: device)
        try device.lockForConfiguration()
        device.ramp(toVideoZoomFactor: clamped, withRate: rate)
        device.unlockForConfiguration()
    }

    /// Cancels an in-progress zoom ramp.
    ///
    /// - Parameter device: The capture device.
    /// - Throws: If the device cannot be locked for configuration.
    public static func cancelZoomRamp(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        device.cancelVideoZoomRamp()
        device.unlockForConfiguration()
    }

    // MARK: - Queries

    /// The minimum zoom factor supported by the device.
    public static func minZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        device.minAvailableVideoZoomFactor
    }

    /// The maximum zoom factor supported by the device.
    public static func maxZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        device.maxAvailableVideoZoomFactor
    }

    /// The current zoom factor of the device.
    public static func currentZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        device.videoZoomFactor
    }

    /// Returns the virtual device switch-over zoom factors (e.g., 0.5×, 1×, 3× on triple camera).
    ///
    /// Empty on non-virtual devices.
    public static func switchOverZoomFactors(for device: AVCaptureDevice) -> [CGFloat] {
        device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
    }

    // MARK: - Focal Length

    /// A lens descriptor pairing a zoom factor with its approximate 35mm-equivalent focal length.
    public struct LensInfo: Sendable, Equatable {
        /// The raw AVFoundation zoom factor to switch to this lens (use with `setZoomFactor`).
        public let zoomFactor: CGFloat
        /// User-facing zoom multiplier normalized so the wide lens = 1× (e.g., 0.5×, 1×, 5×).
        public let displayZoomFactor: CGFloat
        /// Approximate 35mm-equivalent focal length in millimeters (e.g., 13, 24, 48, 120).
        public let focalLength: Int
    }

    /// Returns lens descriptors for each physical camera in a virtual device, labeled with
    /// approximate 35mm-equivalent focal lengths.
    ///
    /// Builds the zoom factor list from `[minZoomFactor, switchOvers...]`,
    /// then deduplicates and sorts so each entry maps to a distinct physical lens.
    /// The first switchover is the wide lens — all `displayZoomFactor` values are normalized
    /// so the wide lens = 1× (matching Apple Camera app convention).
    ///
    /// Returns an empty array on non-virtual devices (no constituent lenses to switch between).
    ///
    /// ```swift
    /// let lenses = PRMZoomHelper.lensInfos(for: device)
    /// // iPhone 15 Pro Max triple camera:
    /// // [LensInfo(zoomFactor: 1.0, displayZoomFactor: 0.5, focalLength: 13),
    /// //  LensInfo(zoomFactor: 2.0, displayZoomFactor: 1.0, focalLength: 24),
    /// //  LensInfo(zoomFactor: 10.0, displayZoomFactor: 5.0, focalLength: 120)]
    /// ```
    public static func lensInfos(for device: AVCaptureDevice) -> [LensInfo] {
        let switchOvers = switchOverZoomFactors(for: device)
        guard !switchOvers.isEmpty else { return [] }

        // Collect all lens switch points: ultra-wide (min) + each switch-over
        var factors: Set<CGFloat> = [minZoomFactor(for: device)]
        for factor in switchOvers {
            factors.insert(factor)
        }
        let sorted = factors.sorted()

        // Normalize so wide lens (first switchover) = 1×
        let wideFactor = switchOvers[0]

        return sorted.map { factor in
            let raw = focalLength35mm(for: device, atZoomFactor: factor)
            return LensInfo(
                zoomFactor: factor,
                displayZoomFactor: factor / wideFactor,
                focalLength: snapToStandardFocalLength(raw),
            )
        }
    }

    /// Computes the approximate 35mm-equivalent focal length at a given zoom factor.
    ///
    /// Derived from the active format's horizontal field of view:
    /// `focal_35mm = 36mm / (2 × tan(FOV/2)) × zoomFactor`
    ///
    /// The result is approximate — `videoFieldOfView` on virtual devices may not perfectly
    /// match marketing specs. Use ``lensInfos(for:)`` for snapped standard values.
    ///
    /// - Parameters:
    ///   - device: The capture device.
    ///   - zoomFactor: The zoom factor (defaults to the device's current zoom).
    /// - Returns: Approximate 35mm-equivalent focal length in millimeters.
    public static func focalLength35mm(
        for device: AVCaptureDevice,
        atZoomFactor zoomFactor: CGFloat? = nil,
    ) -> Double {
        let fovDegrees = Double(device.activeFormat.videoFieldOfView)
        guard fovDegrees > 0 else { return 0 }

        let fovRadians = fovDegrees * .pi / 180.0
        let baseFocal = sensorWidth35mm / (2.0 * tan(fovRadians / 2.0))
        let zoom = Double(zoomFactor ?? currentZoomFactor(for: device))
        return baseFocal * zoom
    }

    // MARK: - Private

    /// 35mm film sensor width in millimeters.
    private static let sensorWidth35mm: Double = 36.0

    /// Known phone camera focal lengths (mm). Only includes values used by real phone cameras.
    /// Snapping to these corrects the ~15% overestimation from `videoFieldOfView` on virtual devices.
    private static let standardFocalLengths = [
        13, 15, 23, 24, 26, 48, 50, 52, 65, 70, 77, 120, 200,
    ]

    /// Snaps a calculated focal length to the lowest standard value within 20% tolerance.
    ///
    /// `videoFieldOfView` on virtual devices consistently overestimates focal length,
    /// so among all candidates within tolerance, the lowest is the most accurate match.
    private static func snapToStandardFocalLength(_ calculated: Double) -> Int {
        let candidates = standardFocalLengths.filter { standard in
            abs(Double(standard) - calculated) <= Double(standard) * 0.2
        }
        if let best = candidates.min() {
            return best
        }
        return Int(round(calculated))
    }

    private static func clampedZoomFactor(_ factor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }
}
