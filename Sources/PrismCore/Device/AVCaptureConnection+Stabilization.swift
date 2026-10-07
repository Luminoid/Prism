import AVFoundation

public extension AVCaptureConnection {
    /// Sets the preferred stabilization mode if supported. No-op otherwise.
    ///
    /// The system may fall back to a less aggressive mode based on the active device/format.
    /// Read `activeVideoStabilizationMode` afterwards to see what was actually applied.
    ///
    /// iOS 26 adds `.lowLatency`: a reduced field of view like `.standard`, but with no
    /// added pipeline latency, which suits live preview and real-time processing.
    func prm_setStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        guard isVideoStabilizationSupported else { return }
        preferredVideoStabilizationMode = mode
    }
}
