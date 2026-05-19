import AVFoundation

public extension AVCaptureConnection {
    /// Sets the preferred stabilization mode if supported. No-op otherwise.
    ///
    /// The system may fall back to a less aggressive mode based on the active device/format.
    /// Read `activeVideoStabilizationMode` afterwards to see what was actually applied.
    func prm_setStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        guard isVideoStabilizationSupported else { return }
        preferredVideoStabilizationMode = mode
    }
}
