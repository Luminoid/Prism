import AVFoundation

// iOS 26 Cinematic Video device helpers. Enabling Cinematic Video itself is a session
// operation (it lives on the device *input*); see `PRMCameraSession.setCinematicVideoCaptureEnabled`.

public extension AVCaptureDevice.Format {
    /// Frame-rate range available while Cinematic Video is enabled on this format, or `nil`
    /// when the format doesn't support Cinematic Video (or the OS is older than iOS 26).
    var prm_cinematicFrameRateRange: ClosedRange<Float64>? {
        guard #available(iOS 26.0, *), let range = videoFrameRateRangeForCinematicVideo else { return nil }
        return range.minFrameRate ... range.maxFrameRate
    }

    /// Simulated-aperture range for Cinematic Video's depth-of-field effect, or `nil` when the
    /// format can't change it (or the OS is older than iOS 26).
    var prm_simulatedApertureRange: ClosedRange<Float>? {
        guard #available(iOS 26.0, *) else { return nil }
        guard minSimulatedAperture > 0, maxSimulatedAperture >= minSimulatedAperture else { return nil }
        return minSimulatedAperture ... maxSimulatedAperture
    }
}

public extension AVCaptureDevice {
    /// Scene conditions currently degrading Cinematic Video (iOS 26). Empty before that.
    var prm_cinematicSceneStatuses: Set<PRMSceneMonitoringStatus> {
        guard #available(iOS 26.0, *) else { return [] }
        return Set(cinematicVideoCaptureSceneMonitoringStatuses.map(PRMSceneMonitoringStatus.init))
    }

    /// Sends a Cinematic Video focus command (iOS 26): track a detected object, track
    /// whatever is at a point, or fix focus at a point's distance.
    ///
    /// Only meaningful while Cinematic Video capture is enabled on the session's input.
    /// While it is, ordinary focus-mode changes raise `NSInvalidArgumentException`; use this
    /// instead.
    @available(iOS 26.0, *)
    func prm_setCinematicFocus(_ request: PRMCinematicFocusRequest) throws {
        try prm_withConfigurationLock {
            switch request {
            case let .trackObject(id, mode):
                setCinematicVideoTrackingFocus(detectedObjectID: id, focusMode: mode.avMode)
            case let .trackPoint(point, mode):
                setCinematicVideoTrackingFocus(at: Self.prm_clampedUnitPoint(point), focusMode: mode.avMode)
            case let .fixedPoint(point, mode):
                setCinematicVideoFixedFocus(at: Self.prm_clampedUnitPoint(point), focusMode: mode.avMode)
            }
        }
    }
}

// MARK: - Format selection

extension AVCaptureDevice {
    /// Picks the format to switch to for Cinematic Video: among formats that support it,
    /// the one closest in pixel count to `preferredDimensions` (the current format, so the
    /// preview doesn't jump in resolution), ties broken by the higher cinematic frame rate.
    /// `nil` when no format supports Cinematic Video.
    @available(iOS 26.0, *)
    static func prm_bestCinematicFormat(
        from formats: [AVCaptureDevice.Format],
        preferredDimensions: CMVideoDimensions
    ) -> AVCaptureDevice.Format? {
        let target = Int64(preferredDimensions.width) * Int64(preferredDimensions.height)
        return formats
            .filter(\.isCinematicVideoCaptureSupported)
            .min { lhs, rhs in
                let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let lhsDistance = abs(Int64(lhsDims.width) * Int64(lhsDims.height) - target)
                let rhsDistance = abs(Int64(rhsDims.width) * Int64(rhsDims.height) - target)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                let lhsRate = lhs.videoFrameRateRangeForCinematicVideo?.maxFrameRate ?? 0
                let rhsRate = rhs.videoFrameRateRangeForCinematicVideo?.maxFrameRate ?? 0
                return lhsRate > rhsRate
            }
    }
}
