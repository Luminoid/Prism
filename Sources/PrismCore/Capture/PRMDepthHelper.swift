import AVFoundation

/// Helpers for configuring depth data capture on `AVCapturePhotoOutput` and `AVCaptureDepthDataOutput`.
///
/// Depth data is available on devices with dual/triple camera systems (e.g., iPhone 12+).
/// ```swift
/// if PRMDepthHelper.isDepthCaptureSupported(on: photoOutput) {
///     PRMDepthHelper.enableDepthDataDelivery(on: photoOutput)
/// }
/// ```
public enum PRMDepthHelper: Sendable {
    // MARK: - Photo Output Depth

    /// Whether the photo output supports depth data delivery.
    public static func isDepthCaptureSupported(on photoOutput: AVCapturePhotoOutput) -> Bool {
        photoOutput.isDepthDataDeliverySupported
    }

    /// Enables depth data delivery on the photo output.
    ///
    /// Call this after adding the photo output to the session and configuring inputs.
    /// No-op if depth is not supported.
    public static func enableDepthDataDelivery(on photoOutput: AVCapturePhotoOutput) {
        guard photoOutput.isDepthDataDeliverySupported else { return }
        photoOutput.isDepthDataDeliveryEnabled = true
    }

    /// Disables depth data delivery on the photo output.
    public static func disableDepthDataDelivery(on photoOutput: AVCapturePhotoOutput) {
        photoOutput.isDepthDataDeliveryEnabled = false
    }

    /// Whether depth data delivery is currently enabled on the photo output.
    public static func isDepthDataDeliveryEnabled(on photoOutput: AVCapturePhotoOutput) -> Bool {
        photoOutput.isDepthDataDeliveryEnabled
    }

    // MARK: - Depth Data Output

    /// Creates and adds an `AVCaptureDepthDataOutput` to the session.
    ///
    /// - Parameters:
    ///   - session: The capture session to add the output to.
    ///   - delegate: The delegate that will receive depth data updates.
    ///   - queue: The dispatch queue for delegate callbacks.
    /// - Returns: The configured depth data output, or `nil` if it can't be added.
    @discardableResult
    public static func addDepthDataOutput(
        to session: AVCaptureSession,
        delegate: any AVCaptureDepthDataOutputDelegate,
        queue: DispatchQueue,
    ) -> AVCaptureDepthDataOutput? {
        let depthOutput = AVCaptureDepthDataOutput()
        guard session.canAddOutput(depthOutput) else { return nil }
        session.addOutput(depthOutput)
        depthOutput.setDelegate(delegate, callbackQueue: queue)
        return depthOutput
    }

    /// Sets whether the depth data output applies temporal smoothing (filtering).
    public static func setFilteringEnabled(_ enabled: Bool, on output: AVCaptureDepthDataOutput) {
        output.isFilteringEnabled = enabled
    }

    /// Whether temporal smoothing is enabled on the depth data output.
    public static func isFilteringEnabled(on output: AVCaptureDepthDataOutput) -> Bool {
        output.isFilteringEnabled
    }
}
