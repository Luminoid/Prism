@preconcurrency import AVFoundation

/// Helpers for configuring depth data on `AVCapturePhotoOutput` and `AVCaptureDepthDataOutput`.
///
/// Depth data is available on devices with dual/triple camera systems (iPhone 12+).
/// ```swift
/// if PRMDepthCapture.isSupported(on: photoOutput) {
///     PRMDepthCapture.setEnabled(true, on: photoOutput)
/// }
/// ```
///
/// For a live depth stream use ``PRMCameraSession/attachDepthDataOutput(delegate:queue:filteringEnabled:)``,
/// which the session tracks across reconfigures.
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

    /// Adds a depth data output to a raw `AVCaptureSession`, outside any begin/commit and
    /// without telling ``PRMCameraSession``, so a reconfigure or Cinematic Video can't
    /// account for it.
    @available(*, deprecated, message: "Use PRMCameraSession.attachDepthDataOutput(delegate:queue:filteringEnabled:)")
    @discardableResult
    public static func addDepthDataOutput(
        to session: AVCaptureSession,
        delegate: any AVCaptureDepthDataOutputDelegate,
        queue: DispatchQueue
    ) -> AVCaptureDepthDataOutput? {
        // AVFoundation raises when a depth data output runs alongside Cinematic Video.
        if #available(iOS 26.0, *),
           session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.isCinematicVideoCaptureEnabled == true }) {
            PRMLog.warning(.session, "addDepthDataOutput: refused while Cinematic Video is enabled")
            return nil
        }
        let output = AVCaptureDepthDataOutput()
        guard session.canAddOutput(output) else {
            PRMLog.warning(.session, "addDepthDataOutput: the session can't add a depth data output")
            return nil
        }
        session.addOutput(output)
        output.setDelegate(delegate, callbackQueue: queue)
        return output
    }

    public static func setFiltering(_ enabled: Bool, on output: AVCaptureDepthDataOutput) {
        output.isFilteringEnabled = enabled
    }
}

// MARK: - Session-owned depth stream

public extension PRMCameraSession {
    /// Adds a live depth stream (`AVCaptureDepthDataOutput`) in one begin/commit and waits for
    /// the rebuild to settle. The session keeps it across full reconfigures (re-attached with
    /// the same delegate) until ``detachDepthDataOutput()`` or the next ``configure(_:)``.
    /// Calling it again with a stream attached only updates the delegate and filtering.
    ///
    /// Pair it with ``PRMCamera/enableDepthFormat()``: the default `.photo` preset on Pro
    /// iPhones picks a format that streams no depth.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while Cinematic Video is
    ///   enabled (AVFoundation raises when both run), or
    ///   ``PRMSessionError/cannotAttachToSession(_:)`` when the session can't add the output.
    @discardableResult
    func attachDepthDataOutput(
        delegate: any AVCaptureDepthDataOutputDelegate,
        queue: DispatchQueue,
        filteringEnabled: Bool = true
    ) async throws -> AVCaptureDepthDataOutput {
        if isCinematicVideoCaptureActive {
            throw PRMSessionError.unsupportedConfiguration("A depth stream can't run while Cinematic Video is enabled")
        }
        depthDataOutputRequest = DepthDataOutputRequest(delegate: delegate, queue: queue, filteringEnabled: filteringEnabled)
        if let depthDataOutput {
            depthDataOutput.setDelegate(delegate, callbackQueue: queue)
            depthDataOutput.isFilteringEnabled = filteringEnabled
            return depthDataOutput
        }
        session.beginConfiguration()
        applyDepthDataOutputAttached()
        session.commitConfiguration()
        guard let depthDataOutput else {
            depthDataOutputRequest = nil
            throw PRMSessionError.cannotAttachToSession("Cannot add depth data output")
        }
        _ = await awaitPhotoOutputReady()
        return depthDataOutput
    }

    /// Removes the depth stream, if any, and waits for the rebuild to settle.
    func detachDepthDataOutput() async {
        depthDataOutputRequest = nil
        guard let output = depthDataOutput else { return }
        session.beginConfiguration()
        session.removeOutput(output)
        depthDataOutput = nil
        session.commitConfiguration()
        _ = await awaitPhotoOutputReady()
    }
}

extension PRMCameraSession {
    /// Adds the requested depth output inside an open begin/commit. Logs when the session
    /// refuses it.
    func applyDepthDataOutputAttached() {
        guard depthDataOutput == nil, let request = depthDataOutputRequest else { return }
        let output = AVCaptureDepthDataOutput()
        guard session.canAddOutput(output) else {
            PRMLog.warning(.session, "Cannot add depth data output")
            return
        }
        session.addOutput(output)
        output.setDelegate(request.delegate, callbackQueue: request.queue)
        output.isFilteringEnabled = request.filteringEnabled
        depthDataOutput = output
    }
}
