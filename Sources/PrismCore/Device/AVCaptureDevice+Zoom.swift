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

    /// Returns lens descriptors for each physical camera in this virtual device, plus
    /// any virtual "lenses" exposed as native-resolution sensor crops (e.g. the 2× crop
    /// on iPhones with a 48MP main sensor — Apple Camera surfaces this as a third chip
    /// alongside the physical lenses, because at native resolution the crop yields a
    /// 12MP image without upscaling).
    ///
    /// Builds the zoom-factor list from `[minZoomFactor, switchOvers..., nativeCrops...]`,
    /// deduplicates, sorts, and computes the raw 35mm-equivalent focal length at each.
    /// The first switch-over is the wide lens — all `displayZoomFactor` values are
    /// normalized so the wide lens equals 1× (Apple Camera convention).
    ///
    /// Returns a single-lens descriptor for physical devices (no virtual switch-overs),
    /// matching the device's own FOV-derived focal length at the minimum zoom factor.
    /// Without this fallback, callers that compute focal length via lens lookup (e.g. the
    /// Studio telemetry strip) render `0mm` whenever the active device is physical (e.g.
    /// after a virtual → wide swap for manual exposure mode).
    func prm_lenses() -> [PRMLens] {
        let switchOvers = virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        guard !switchOvers.isEmpty else {
            let factor = minAvailableVideoZoomFactor
            let focal = prm_focalLength35mm(atZoomFactor: factor)
            return [
                PRMLens(
                    zoomFactor: factor,
                    displayZoomFactor: 1,
                    focalLength35mm: focal,
                    deviceType: deviceType,
                    kind: .physical
                ),
            ]
        }

        var factors: Set<CGFloat> = [minAvailableVideoZoomFactor]
        for value in switchOvers {
            factors.insert(value)
        }
        // Pull the native-resolution crop points off the *active* format. iPhone 14/15/16
        // base models surface `[2.0]` (2× crop of the 48MP main sensor → 48mm equiv at
        // 12MP). iPhone 14/15/16 Pro additionally surface `[4.0]` for the 4× crop that
        // lines up with the 3× telephoto's FOV. Some formats (low-resolution video,
        // older devices) return an empty array — we just skip the extra chips then.
        let nativeCrops = activeFormat.secondaryNativeResolutionZoomFactors
        for value in nativeCrops {
            factors.insert(value)
        }
        let sorted = factors.sorted()
        let wideFactor = switchOvers[0]

        // Pair each *physical* zoom-factor bucket with its constituent device.
        // AVFoundation doesn't expose this mapping directly, but `constituentDevices`
        // sorted by typical focal length (ultrawide < wide < telephoto1 < telephoto2)
        // lines up index-for-index with the *switch-over* factors in order — the lowest
        // factor uses the widest-FOV lens, and each subsequent factor steps up. Build a
        // factor→deviceType lookup so native-crop factors mixed into `sorted` don't
        // shift the indices and end up labeled with the wrong physical lens.
        let physicalFactors = ([minAvailableVideoZoomFactor] + switchOvers).sorted()
        let constituents = constituentDevices
            .sorted { lhs, rhs in
                deviceTypeRank(lhs.deviceType) < deviceTypeRank(rhs.deviceType)
            }
        var deviceTypeByFactor: [CGFloat: AVCaptureDevice.DeviceType] = [:]
        for (index, factor) in physicalFactors.enumerated() where index < constituents.count {
            deviceTypeByFactor[factor] = constituents[index].deviceType
        }
        let nativeCropSet = Set(nativeCrops)

        return sorted.map { factor in
            let isCrop = nativeCropSet.contains(factor) && deviceTypeByFactor[factor] == nil
            return PRMLens(
                zoomFactor: factor,
                displayZoomFactor: factor / wideFactor,
                focalLength35mm: prm_focalLength35mm(atZoomFactor: factor),
                deviceType: deviceTypeByFactor[factor],
                kind: isCrop ? .nativeResolutionCrop : .physical
            )
        }
    }

    /// Sort key for arranging constituent devices ultrawide → wide → telephoto. Higher
    /// values = narrower field of view (more zoomed in). Unknown device types sink to
    /// the bottom so they don't pre-empt known ones.
    private func deviceTypeRank(_ type: AVCaptureDevice.DeviceType) -> Int {
        switch type {
        case .builtInUltraWideCamera: 0
        case .builtInWideAngleCamera: 1
        case .builtInTelephotoCamera: 2
        default: 99
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
