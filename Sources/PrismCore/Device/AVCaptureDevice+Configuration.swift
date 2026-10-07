import AVFoundation
import os

public extension AVCaptureDevice {
    /// Runs `body` inside a paired `lockForConfiguration()` / `unlockForConfiguration()`
    /// scope, guaranteeing the unlock fires even if `body` throws or returns early. Folds
    /// the boilerplate that every manual setter (`+Exposure`, `+WhiteBalance`, `+ISO`,
    /// `+Lens`, `+FrameRate`, `+Zoom`, `+Torch`, `+HDR`) used to repeat inline.
    ///
    /// Forwards exceptions from `lockForConfiguration()` (and from `body`) untouched —
    /// AVFoundation's lock error has a specific reason code callers may want to inspect.
    func prm_withConfigurationLock<T>(_ body: () throws -> T) throws -> T {
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        return try body()
    }

    /// Renamed ``prm_withConfigurationLock(_:)``; the unprefixed name could collide with an
    /// app's own `AVCaptureDevice` extension.
    @available(*, deprecated, renamed: "prm_withConfigurationLock(_:)")
    func withConfigurationLock<T>(_ body: () throws -> T) throws -> T {
        try prm_withConfigurationLock(body)
    }

    /// `true` for `.builtInTripleCamera`, `.builtInDualCamera`, `.builtInDualWideCamera`
    /// (and any future virtual multi-camera AVFoundation may add).
    ///
    /// Why this matters: virtual devices aggregate multiple constituent physical cameras
    /// whose auto-AE / auto-AWB systems keep re-asserting themselves. Per Apple's
    /// white-balance docs: *"exposure duration, ISO, aperture, white balance gains, or
    /// lens position may change when the device switches from one camera to the other."*
    /// User-visible symptom: `setExposureModeCustom` / `setWhiteBalanceModeLocked`
    /// "return success" but the slider drag doesn't change preview color, ISO/shutter
    /// labels update but the saved photo's EXIF shows continuous-auto values. The
    /// canonical workaround is to switch to the physical `.builtInWideAngleCamera`
    /// before issuing manual controls.
    ///
    /// `virtualDeviceSwitchOverVideoZoomFactors` is the AVFoundation-documented signal
    /// — empty on single-lens devices, populated with the zoom factors at which the
    /// virtual device transitions between its constituent cameras.
    var prm_isVirtualMultiCameraDevice: Bool {
        !virtualDeviceSwitchOverVideoZoomFactors.isEmpty
    }
}

// MARK: - Internal helpers

extension AVCaptureDevice {
    /// Clamps a device-space point into `0...1` on both axes; non-finite coordinates
    /// become the center. AVFoundation raises on points of interest outside the unit square.
    static func prm_clampedUnitPoint(_ point: CGPoint) -> CGPoint {
        func clamp(_ value: CGFloat) -> CGFloat {
            value.isFinite ? min(max(value, 0), 1) : 0.5
        }
        return CGPoint(x: clamp(point.x), y: clamp(point.y))
    }

    /// Device settings Prism changed on its own (rather than at the app's request), keyed
    /// by `uniqueID`, so Prism restores only what it turned off itself.
    enum PRMAutoAdjustment: Hashable {
        /// `automaticallyAdjustsVideoHDREnabled`, turned off for full manual exposure.
        case videoHDR
        /// `isGeometricDistortionCorrectionEnabled`, turned off for a depth format.
        case geometricDistortionCorrection
    }

    private static let prismDisabledAdjustments = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private func prm_adjustmentKey(_ adjustment: PRMAutoAdjustment) -> String {
        "\(uniqueID)|\(adjustment)"
    }

    /// Records that Prism turned `adjustment` off on this device.
    func prm_noteDisabledByPrism(_ adjustment: PRMAutoAdjustment) {
        let key = prm_adjustmentKey(adjustment)
        Self.prismDisabledAdjustments.withLock { _ = $0.insert(key) }
    }

    /// Clears the record (the app took over the setting, or Prism restored it). Returns
    /// whether Prism had turned it off.
    @discardableResult
    func prm_clearDisabledByPrism(_ adjustment: PRMAutoAdjustment) -> Bool {
        let key = prm_adjustmentKey(adjustment)
        return Self.prismDisabledAdjustments.withLock { $0.remove(key) != nil }
    }

    /// Starts a device change whose AVFoundation completion handler fires once the change
    /// reaches a frame, and waits for it. Gives up after `timeout` seconds with
    /// ``PRMSessionError/unsupportedConfiguration(_:)`` (`timeoutMessage`), because the handler
    /// never runs while no frames flow (session stopped or interrupted). `start` receives a
    /// resume-once callback; if it throws, that error is rethrown.
    static func prm_awaitDeviceCommit(
        timeout: TimeInterval,
        timeoutMessage: String,
        _ start: (@escaping @Sendable (Result<CMTime, any Error>) -> Void) throws -> Void
    ) async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Result<CMTime, any Error>) -> Void = { result in
                let isFirst = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(with: result) }
            }
            do {
                try start(resumeOnce)
            } catch {
                resumeOnce(.failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(PRMSessionError.unsupportedConfiguration(timeoutMessage)))
            }
        }
    }

    /// Turns geometric distortion correction back on if ``prm_enableDepthFormat()`` turned
    /// it off. Call when the device leaves a depth format or the session. Takes the
    /// configuration lock itself.
    func prm_restoreGeometricDistortionCorrectionIfNeeded() {
        #if !os(macOS)
            guard prm_clearDisabledByPrism(.geometricDistortionCorrection),
                  isGeometricDistortionCorrectionSupported, !isGeometricDistortionCorrectionEnabled
            else { return }
            PRMLog.bestEffort(.session, "restore geometric distortion correction") {
                try prm_withConfigurationLock { isGeometricDistortionCorrectionEnabled = true }
            }
        #endif
    }
}
