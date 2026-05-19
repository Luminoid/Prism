import AVFoundation

/// Helpers for configuring depth data on `AVCapturePhotoOutput` and `AVCaptureDepthDataOutput`.
///
/// Depth data is available on devices with dual/triple camera systems (iPhone 12+).
/// ```swift
/// if PRMDepthCapture.isSupported(on: photoOutput) {
///     PRMDepthCapture.setEnabled(true, on: photoOutput)
/// }
/// ```
public enum PRMDepthCapture: Sendable {
    // MARK: - Photo Output

    public static func isSupported(on photoOutput: AVCapturePhotoOutput) -> Bool {
        photoOutput.isDepthDataDeliverySupported
    }

    public static func setEnabled(_ enabled: Bool, on photoOutput: AVCapturePhotoOutput) {
        guard photoOutput.isDepthDataDeliverySupported else { return }
        photoOutput.isDepthDataDeliveryEnabled = enabled
    }

    public static func isEnabled(on photoOutput: AVCapturePhotoOutput) -> Bool {
        photoOutput.isDepthDataDeliveryEnabled
    }

    // MARK: - Depth Data Output (live depth stream)

    /// Adds a depth data output to the session.
    @discardableResult
    public static func addDepthDataOutput(
        to session: AVCaptureSession,
        delegate: any AVCaptureDepthDataOutputDelegate,
        queue: DispatchQueue
    ) -> AVCaptureDepthDataOutput? {
        let output = AVCaptureDepthDataOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        output.setDelegate(delegate, callbackQueue: queue)
        return output
    }

    public static func setFiltering(_ enabled: Bool, on output: AVCaptureDepthDataOutput) {
        output.isFilteringEnabled = enabled
    }
}
