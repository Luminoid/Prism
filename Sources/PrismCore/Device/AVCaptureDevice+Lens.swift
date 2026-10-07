import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    /// Sets the focus mode.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device doesn't
    ///   support `mode`, or AVFoundation's lock error.
    func prm_setFocusMode(_ mode: AVCaptureDevice.FocusMode) throws {
        guard isFocusModeSupported(mode) else {
            throw PRMSessionError.unsupportedConfiguration("Focus mode \(mode.rawValue) isn't supported by \(localizedName)")
        }
        try prm_withConfigurationLock {
            focusMode = mode
        }
    }

    /// Whether the device can lock focus at a custom lens position.
    ///
    /// **`isFocusModeSupported(.locked)` is necessary but not sufficient** — virtual
    /// devices (`.builtInTripleCamera`, `.builtInDualCamera`, `.builtInDualWideCamera`)
    /// often report `.locked` as supported but raise `NSInvalidArgumentException`
    /// (*"`-[AVCaptureDevice setFocusModeLockedWithLensPosition:completionHandler:]`
    /// Unsupported - use `-[isLockingFocusWithCustomLensPositionSupported]`"*) when
    /// `setFocusModeLocked(lensPosition:completionHandler:)` is called. The custom-
    /// lens-position capability is a separate gate that newer iOS releases enforce
    /// strictly. Apps that need manual focus on virtual devices must first hop to
    /// `.builtInWideAngleCamera` (same pattern as manual exposure).
    var prm_supportsCustomLensPosition: Bool {
        isFocusModeSupported(.locked) && isLockingFocusWithCustomLensPositionSupported
    }

    /// Locks focus at a lens position (0.0 = near focus, 1.0 = far focus) and waits until
    /// the lens has physically moved.
    ///
    /// - Parameters:
    ///   - position: Target lens position in `0...1`. Values outside the range are clamped.
    ///   - timeout: Seconds to wait for a frame to confirm the move.
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device can't lock
    ///   a custom lens position (see ``prm_supportsCustomLensPosition``) or no frame confirms
    ///   the move within `timeout` seconds (the session is stopped or interrupted), or
    ///   AVFoundation's lock error.
    func prm_setLensPosition(_ position: Float, timeout: TimeInterval = 2) async throws {
        _ = try await Self.prm_awaitDeviceCommit(
            timeout: timeout,
            timeoutMessage: "No frame confirmed the lens move within \(Int(timeout)) s"
        ) { resume in
            try prm_setLensPosition(position) { time in resume(.success(time)) }
        }
    }

    /// Locks focus at a lens position without waiting; `completion` fires when the lens has
    /// moved. Same gate and clamping as the async overload.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the device can't lock
    ///   a custom lens position, or AVFoundation's lock error. `completion` only runs when
    ///   this returns without throwing.
    func prm_setLensPosition(_ position: Float, completion: @escaping @Sendable (CMTime) -> Void) throws {
        guard prm_supportsCustomLensPosition else {
            throw PRMSessionError.unsupportedConfiguration("\(localizedName) can't lock focus at a custom lens position")
        }
        let clamped = position.isFinite ? min(max(position, 0.0), 1.0) : 0.5
        try prm_withConfigurationLock {
            setFocusModeLocked(lensPosition: clamped) { time in completion(time) }
        }
    }

    /// Renamed: this is the non-waiting variant, now spelled
    /// ``prm_setLensPosition(_:completion:)``.
    @available(*, deprecated, renamed: "prm_setLensPosition(_:completion:)")
    func prm_setLensPositionAsync(_ position: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        try prm_setLensPosition(position) { time in completion?(time) }
    }
}
