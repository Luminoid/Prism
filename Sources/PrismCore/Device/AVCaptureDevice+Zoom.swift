import AVFoundation

/// 35mm film sensor width in millimeters — used to compute 35mm-equivalent focal length.
private let sensorWidth35mm: Double = 36.0

public extension AVCaptureDevice {
    // MARK: - Set Zoom

    /// Sets the zoom factor, clamped to the device's supported range.
    ///
    /// - Throws: If the device cannot be locked for configuration.
    func prm_setZoom(_ factor: CGFloat) throws {
        let clamped = min(max(factor, minAvailableVideoZoomFactor), maxAvailableVideoZoomFactor)
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        videoZoomFactor = clamped
    }

    /// Begins a smooth zoom ramp.
    ///
    /// - Parameters:
    ///   - factor: Target zoom factor.
    ///   - rate: Ramp rate (`pow(2, rate × t)`); 1.0 doubles magnification per second.
    func prm_rampZoom(to factor: CGFloat, rate: Float = 1.0) throws {
        let clamped = min(max(factor, minAvailableVideoZoomFactor), maxAvailableVideoZoomFactor)
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        ramp(toVideoZoomFactor: clamped, withRate: rate)
    }

    /// Cancels an in-progress zoom ramp.
    func prm_cancelZoomRamp() throws {
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        cancelVideoZoomRamp()
    }

    // MARK: - Lens Descriptors

    /// Returns lens descriptors for each physical camera in this virtual device.
    ///
    /// Builds the zoom-factor list from `[minZoomFactor, switchOvers...]`, deduplicates,
    /// sorts, and computes the raw 35mm-equivalent focal length at each. The first
    /// switch-over is the wide lens — all `displayZoomFactor` values are normalized so the
    /// wide lens equals 1× (Apple Camera convention).
    ///
    /// Returns an empty array on non-virtual devices.
    func prm_lenses() -> [PRMLens] {
        let switchOvers = virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        guard !switchOvers.isEmpty else { return [] }

        var factors: Set<CGFloat> = [minAvailableVideoZoomFactor]
        for value in switchOvers {
            factors.insert(value)
        }
        let sorted = factors.sorted()
        let wideFactor = switchOvers[0]

        return sorted.map { factor in
            PRMLens(
                zoomFactor: factor,
                displayZoomFactor: factor / wideFactor,
                focalLength35mm: prm_focalLength35mm(atZoomFactor: factor)
            )
        }
    }

    /// Computes the raw 35mm-equivalent focal length at a given zoom factor (defaulting to the
    /// device's current zoom).
    ///
    /// `focal_35mm = 36mm / (2 × tan(FOV/2)) × zoomFactor`
    func prm_focalLength35mm(atZoomFactor zoomFactor: CGFloat? = nil) -> Double {
        let fovDegrees = Double(activeFormat.videoFieldOfView)
        guard fovDegrees > 0 else { return 0 }
        let fovRadians = fovDegrees * .pi / 180.0
        let baseFocal = sensorWidth35mm / (2.0 * tan(fovRadians / 2.0))
        let zoom = Double(zoomFactor ?? videoZoomFactor)
        return baseFocal * zoom
    }
}
