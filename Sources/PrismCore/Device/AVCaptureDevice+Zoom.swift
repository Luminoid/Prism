import AVFoundation

/// 35mm film sensor width in millimeters — used to compute 35mm-equivalent focal length.
private let sensorWidth35mm: Double = 36.0

public extension AVCaptureDevice {
    // MARK: - Set Zoom

    /// Sets the zoom factor, clamped to the device's supported range.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` for a non-finite factor
    ///   (AVFoundation raises on it), or AVFoundation's lock error.
    func prm_setZoom(_ factor: CGFloat) throws {
        let clamped = try prm_clampedZoomFactor(factor)
        try prm_withConfigurationLock {
            videoZoomFactor = clamped
        }
    }

    /// Begins a smooth zoom ramp.
    ///
    /// - Parameters:
    ///   - factor: Target zoom factor.
    ///   - rate: Ramp rate (`pow(2, rate × t)`); 1.0 doubles magnification per second.
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` for a non-finite factor or
    ///   rate, or AVFoundation's lock error.
    func prm_rampZoom(to factor: CGFloat, rate: Float = 1.0) throws {
        let clamped = try prm_clampedZoomFactor(factor)
        guard rate.isFinite, rate > 0 else {
            throw PRMSessionError.unsupportedConfiguration("Zoom ramp rate must be a positive number")
        }
        try prm_withConfigurationLock {
            ramp(toVideoZoomFactor: clamped, withRate: rate)
        }
    }

    /// Cancels an in-progress zoom ramp.
    func prm_cancelZoomRamp() throws {
        try prm_withConfigurationLock {
            cancelVideoZoomRamp()
        }
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
    /// `displayZoomFactor` uses `displayVideoZoomFactorMultiplier`, so the wide lens reads 1×
    /// (Apple Camera convention) whether the virtual device starts at the ultra-wide (Triple,
    /// DualWide) or at the wide lens (Dual, wide + telephoto).
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
            let nominal = Self.prm_nominalFocalLength(
                atZoomFactor: factor,
                physicalLenses: [PRMLensFocalLength(factor: factor, nominal: prm_nominalFocalLength35mm)]
            )
            return [
                PRMLens(
                    zoomFactor: factor,
                    displayZoomFactor: 1,
                    focalLength35mm: nominal ?? prm_focalLength35mm(atZoomFactor: factor),
                    deviceType: deviceType,
                    kind: .physical,
                    focalLengthSource: nominal == nil ? .fieldOfView : .nominal
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
        let displayMultiplier = Self.prm_displayZoomMultiplier(
            reported: displayVideoZoomFactorMultiplier,
            firstSwitchOver: switchOvers[0]
        )

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
        var nominalByFactor: [PRMLensFocalLength] = []
        for (index, factor) in physicalFactors.enumerated() where index < constituents.count {
            deviceTypeByFactor[factor] = constituents[index].deviceType
            nominalByFactor.append(PRMLensFocalLength(factor: factor, nominal: constituents[index].prm_nominalFocalLength35mm))
        }
        let nativeCropSet = Set(nativeCrops)

        return sorted.map { factor in
            let isCrop = nativeCropSet.contains(factor) && deviceTypeByFactor[factor] == nil
            let nominal = Self.prm_nominalFocalLength(atZoomFactor: factor, physicalLenses: nominalByFactor)
            return PRMLens(
                zoomFactor: factor,
                displayZoomFactor: factor * displayMultiplier,
                focalLength35mm: nominal ?? prm_focalLength35mm(atZoomFactor: factor),
                deviceType: deviceTypeByFactor[factor],
                kind: isCrop ? .nativeResolutionCrop : .physical,
                focalLengthSource: nominal == nil ? .fieldOfView : .nominal
            )
        }
    }

    /// iOS 26 `nominalFocalLengthIn35mmFilm` for this (physical) device, or `0` when
    /// unavailable: before iOS 26, and on virtual devices and external cameras.
    var prm_nominalFocalLength35mm: Double {
        guard #available(iOS 26.0, *) else { return 0 }
        return Double(nominalFocalLengthIn35mmFilm)
    }

    // MARK: - Lens lock (iOS 27)

    /// Whether the virtual device is pinned to one constituent lens (iOS 27 lock, or any
    /// `.locked` switching behavior).
    var prm_isPrimaryConstituentLocked: Bool {
        primaryConstituentDeviceSwitchingBehavior == .locked
    }

    /// Pins a virtual device to the constituent lens of `type` (iOS 27), so low light or a
    /// close subject can't make AVFoundation fall back to another lens. Pass `nil` to return
    /// to automatic switching. Zoom is clamped into the locked lens's range by AVFoundation.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` before iOS 27, when the
    ///   device doesn't support locking, or when it has no constituent of `type`.
    func prm_lockPrimaryConstituent(to type: AVCaptureDevice.DeviceType?) throws {
        guard #available(iOS 27.0, *), isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported else {
            throw PRMSessionError.unsupportedConfiguration("Locking to one lens requires iOS 27 and a virtual camera that supports it")
        }
        guard let type else {
            try prm_withConfigurationLock {
                setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            }
            return
        }
        guard let constituent = constituentDevices.first(where: { $0.deviceType == type }) else {
            throw PRMSessionError.unsupportedConfiguration("No \(type.rawValue) lens on \(localizedName)")
        }
        try prm_withConfigurationLock {
            setPrimaryConstituentDeviceSwitchingBehaviorLockedWith(constituent)
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

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// One zoom-factor-to-focal-length pair for ``prm_nominalFocalLength(atZoomFactor:physicalLenses:)``.
    struct PRMLensFocalLength: Equatable {
        let factor: CGFloat
        let nominal: Double
    }

    /// Nominal 35mm-equivalent focal length at a raw zoom factor, scaled from the widest
    /// physical lens at or below that factor (so a 2× native crop of a 24 mm lens reads
    /// 48 mm). `nil` when no qualifying lens reports a nominal value, in which case callers
    /// fall back to the FOV-derived figure. Pure, so it's unit-testable.
    static func prm_nominalFocalLength(atZoomFactor factor: CGFloat, physicalLenses: [PRMLensFocalLength]) -> Double? {
        let base = physicalLenses
            .filter { $0.factor <= factor && $0.factor > 0 && $0.nominal > 0 }
            .max { $0.factor < $1.factor }
        guard let base else { return nil }
        return base.nominal * Double(factor / base.factor)
    }

    /// Raw-to-display zoom multiplier: the device's own `displayVideoZoomFactorMultiplier`
    /// when it reports one, otherwise the old "first switch-over is the wide lens" guess.
    static func prm_displayZoomMultiplier(reported: CGFloat, firstSwitchOver: CGFloat) -> CGFloat {
        if reported > 0, reported.isFinite { return reported }
        return firstSwitchOver > 0 ? 1 / firstSwitchOver : 1
    }

    /// `factor` clamped to the available zoom range; throws for NaN or infinity.
    func prm_clampedZoomFactor(_ factor: CGFloat) throws -> CGFloat {
        guard factor.isFinite else {
            throw PRMSessionError.unsupportedConfiguration("Zoom factor must be a finite number")
        }
        return min(max(factor, minAvailableVideoZoomFactor), maxAvailableVideoZoomFactor)
    }
}
