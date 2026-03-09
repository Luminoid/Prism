import AVFoundation

/// Protocol for handling camera device state changes.
///
/// All methods have default empty implementations — implement only what you need.
public protocol PRMCameraDelegate: AnyObject, Sendable {
    /// Called when a focus/exposure change has been applied to the device.
    func didUpdateFocusAndExposure(
        at point: CGPoint,
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
    )

    /// Called when the zoom factor changes.
    func didUpdateZoom(factor: CGFloat)

    /// Called when the torch state changes.
    func didUpdateTorch(isOn: Bool, level: Float)

    /// Called when the exposure bias or mode changes.
    func didUpdateExposure(bias: Float, mode: AVCaptureDevice.ExposureMode)

    /// Called when the white balance mode changes.
    func didUpdateWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode)

    /// Called when the camera device switches (e.g., front to back).
    func didSwitchCamera(to device: AVCaptureDevice)
}

/// Default implementations — all optional.
public extension PRMCameraDelegate {
    func didUpdateFocusAndExposure(
        at point: CGPoint,
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
    ) {}

    func didUpdateZoom(factor: CGFloat) {}
    func didUpdateTorch(isOn: Bool, level: Float) {}
    func didUpdateExposure(bias: Float, mode: AVCaptureDevice.ExposureMode) {}
    func didUpdateWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {}
    func didSwitchCamera(to device: AVCaptureDevice) {}
}
