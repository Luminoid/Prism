import AVFoundation
import CoreMedia

public extension AVCaptureDevice {
    /// Sets the focus mode if supported. No-op otherwise.
    func prm_setFocusMode(_ mode: AVCaptureDevice.FocusMode) throws {
        guard isFocusModeSupported(mode) else { return }
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        focusMode = mode
    }

    /// Sets the manual lens position (0.0 = near focus, 1.0 = far focus).
    ///
    /// Requires the device to support `.locked` focus mode. The closure-based AVFoundation
    /// API is wrapped as an `async` continuation, so callers can `await` until the focus
    /// adjustment completes (i.e., the lens has physically moved).
    ///
    /// - Parameter position: Target lens position in `0...1`. Values outside the range are
    ///   clamped.
    /// - Throws: ``PRMSessionError/cannotLockDevice`` if the device cannot be locked, or if
    ///   `.locked` focus is unsupported.
    func prm_setLensPosition(_ position: Float) async throws {
        guard isFocusModeSupported(.locked) else { return }
        let clamped = min(max(position, 0.0), 1.0)
        // Lock, kick off the focus move, unlock — *then* await. Holding the device lock across
        // the `await` would stall any concurrent `lockForConfiguration` caller for the full
        // physical lens-move duration (tens of ms).
        try lockForConfiguration()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            setFocusModeLocked(lensPosition: clamped) { _ in
                continuation.resume()
            }
            unlockForConfiguration()
        }
    }

    /// Synchronous lens-position setter for callers that don't need to await completion.
    func prm_setLensPositionAsync(_ position: Float, completion: (@Sendable (CMTime) -> Void)? = nil) throws {
        guard isFocusModeSupported(.locked) else { return }
        let clamped = min(max(position, 0.0), 1.0)
        try lockForConfiguration()
        defer { unlockForConfiguration() }
        setFocusModeLocked(lensPosition: clamped) { time in completion?(time) }
    }
}
