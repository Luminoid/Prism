import AVFoundation
import os

/// Manages the `AVCaptureSession` lifecycle, device discovery, and observers.
///
/// This is the main extraction from AnimalVision's `CameraViewController` — handles:
/// - Session creation, configuration, and start/stop
/// - Camera device discovery (prefers triple → dual → wide angle)
/// - Video/audio inputs
/// - Video data output (for filter pipeline)
/// - Photo output (for still capture)
/// - Focus/exposure adjustments
/// - Session interruption/error observers
///
/// All session operations are dispatched to an internal `sessionQueue` to avoid blocking the main thread.
public final class PRMCameraSessionManager: @unchecked Sendable {
    // MARK: - Properties

    /// The underlying capture session.
    public let session = AVCaptureSession()

    /// The serial queue for session operations. Expose for clients that need to sync.
    public let sessionQueue = DispatchQueue(label: "com.luminoid.Prism.SessionQueue")

    /// The current session setup result.
    public private(set) var setupResult: PRMSessionSetupResult = .success

    /// The current video device, if any.
    public private(set) var videoDevice: AVCaptureDevice?

    /// The current video device input, if any.
    public private(set) var videoDeviceInput: AVCaptureDeviceInput?

    /// The photo output, if configured.
    public private(set) var photoOutput: AVCapturePhotoOutput?

    /// The video data output, if configured.
    public private(set) var videoDataOutput: AVCaptureVideoDataOutput?

    /// Whether the session is currently running.
    public private(set) var isSessionRunning = false

    /// Delegate for focus/exposure notifications.
    public weak var cameraDelegate: (any PRMCameraDelegate)?

    /// Called when the session starts or stops running.
    public var onSessionRunningChanged: ((_ isRunning: Bool) -> Void)?

    /// Called when the session is interrupted (e.g., phone call, PiP).
    /// The `Int` is the raw value of `AVCaptureSession.InterruptionReason` (unavailable on macOS).
    public var onSessionInterrupted: ((_ reasonRawValue: Int) -> Void)?

    /// Called when a session interruption ends.
    public var onSessionInterruptionEnded: (() -> Void)?

    /// Called when a runtime error occurs.
    public var onSessionRuntimeError: ((_ error: AVError) -> Void)?

    private var keyValueObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [any NSObjectProtocol] = []

    // MARK: - Initialization

    public init() {}

    deinit {
        removeObservers()
    }

    // MARK: - Authorization

    /// Checks camera authorization and updates `setupResult` accordingly.
    ///
    /// Call this on `sessionQueue` before `configureSession()`.
    public func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            }
        default:
            setupResult = .notAuthorized
        }
    }

    // MARK: - Configuration

    /// Configures the session with the given configuration.
    ///
    /// Must be called on `sessionQueue`. Updates `setupResult` on failure.
    ///
    /// - Parameters:
    ///   - configuration: The camera configuration.
    ///   - videoDataOutputDelegate: The delegate to receive video frames (typically a `PRMFilterPipeline`).
    ///   - videoDataOutputQueue: The dispatch queue for frame delivery.
    public func configureSession(
        with configuration: PRMCameraConfiguration,
        videoDataOutputDelegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)? = nil,
        videoDataOutputQueue: DispatchQueue? = nil,
    ) {
        guard setupResult == .success else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = configuration.sessionPreset

        // Video device
        guard let device = bestAvailableVideoDevice(for: configuration.cameraPosition) else {
            PRMLogger.session.error("No video device available for position \(configuration.cameraPosition.rawValue)")
            setupResult = .configurationFailed
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                PRMLogger.session.error("Cannot add video device input to session")
                setupResult = .configurationFailed
                return
            }
            session.addInput(input)
            videoDeviceInput = input
            videoDevice = device
        } catch {
            PRMLogger.session.error("Cannot create video device input: \(error.localizedDescription)")
            setupResult = .configurationFailed
            return
        }

        // Audio device
        if configuration.includesAudio {
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    }
                } catch {
                    PRMLogger.session.warning("Cannot create audio device input: \(error.localizedDescription)")
                }
            }
        }

        // Video data output (for real-time filtering)
        if configuration.includesVideoDataOutput {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: configuration.videoPixelFormat,
            ]
            output.alwaysDiscardsLateVideoFrames = true

            if let delegate = videoDataOutputDelegate, let queue = videoDataOutputQueue {
                output.setSampleBufferDelegate(delegate, queue: queue)
            }

            guard session.canAddOutput(output) else {
                PRMLogger.session.error("Cannot add video data output to session")
                setupResult = .configurationFailed
                return
            }
            session.addOutput(output)
            videoDataOutput = output
        }

        // Photo output
        if configuration.includesPhotoOutput {
            let output = AVCapturePhotoOutput()
            #if !os(macOS)
                output.isLivePhotoCaptureEnabled = output.isLivePhotoCaptureSupported
            #endif
            output.maxPhotoQualityPrioritization = .quality

            guard session.canAddOutput(output) else {
                PRMLogger.session.error("Cannot add photo output to session")
                setupResult = .configurationFailed
                return
            }
            session.addOutput(output)
            photoOutput = output
        }
    }

    // MARK: - Start / Stop

    /// Starts the capture session and adds observers.
    ///
    /// Call on `sessionQueue`.
    public func startSession() {
        guard setupResult == .success else { return }
        session.startRunning()
        isSessionRunning = session.isRunning
        addObservers()
    }

    /// Stops the capture session and removes observers.
    ///
    /// Call on `sessionQueue`.
    public func stopSession() {
        guard setupResult == .success else { return }
        session.stopRunning()
        isSessionRunning = false
        removeObservers()
    }

    // MARK: - Camera Switching

    /// Switches to the camera at the given position.
    ///
    /// Call on `sessionQueue`.
    ///
    /// - Parameter position: The desired camera position.
    /// - Returns: `true` if the switch succeeded.
    @discardableResult
    public func switchCamera(to position: AVCaptureDevice.Position) -> Bool {
        guard let currentInput = videoDeviceInput else { return false }

        guard let newDevice = bestAvailableVideoDevice(for: position) else {
            PRMLogger.session.warning("No video device available for position \(position.rawValue)")
            return false
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            session.beginConfiguration()
            session.removeInput(currentInput)

            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoDeviceInput = newInput
                videoDevice = newDevice
            } else {
                // Fallback: re-add old input
                session.addInput(currentInput)
            }

            session.commitConfiguration()

            if videoDevice === newDevice {
                cameraDelegate?.didSwitchCamera(to: newDevice)
            }

            return true
        } catch {
            PRMLogger.session.error("Cannot switch camera: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Focus / Exposure

    /// Sets the focus and exposure point on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    ///
    /// - Parameters:
    ///   - focusMode: The focus mode to apply.
    ///   - exposureMode: The exposure mode to apply.
    ///   - point: The focus/exposure point in device coordinates (`0,0` = top-left).
    ///   - monitorSubjectAreaChange: Whether to monitor subject area changes after focusing.
    public func focus(
        with focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        at point: CGPoint,
        monitorSubjectAreaChange: Bool,
    ) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()

                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = point
                    device.focusMode = focusMode
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposureMode
                }
                #if !os(macOS)
                    device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                #endif

                device.unlockForConfiguration()

                self.cameraDelegate?.didUpdateFocusAndExposure(
                    at: point,
                    focusMode: focusMode,
                    exposureMode: exposureMode,
                )
            } catch {
                PRMLogger.session.error("Cannot lock device for configuration: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Device Controls (Convenience)

    /// Sets the zoom factor on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setZoom(factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            try? PRMZoomHelper.setZoomFactor(factor, on: device)
            self.cameraDelegate?.didUpdateZoom(factor: device.videoZoomFactor)
        }
    }

    /// Begins a smooth zoom ramp to the target factor.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func rampZoom(to factor: CGFloat, withRate rate: Float = 1.0) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            try? PRMZoomHelper.rampZoom(to: factor, withRate: rate, on: device)
            self.cameraDelegate?.didUpdateZoom(factor: device.videoZoomFactor)
        }
    }

    /// Sets the torch mode on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setTorch(mode: PRMTorchHelper.TorchMode) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            try? PRMTorchHelper.setTorchMode(mode, on: device)
            self.cameraDelegate?.didUpdateTorch(
                isOn: device.isTorchActive,
                level: device.torchLevel,
            )
        }
    }

    /// Sets the exposure bias (EV compensation) on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            try? PRMExposureHelper.setExposureTargetBias(bias, on: device)
            self.cameraDelegate?.didUpdateExposure(
                bias: device.exposureTargetBias,
                mode: device.exposureMode,
            )
        }
    }

    /// Sets the white balance mode on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            try? PRMWhiteBalanceHelper.setWhiteBalanceMode(mode, on: device)
            self.cameraDelegate?.didUpdateWhiteBalance(mode: device.whiteBalanceMode)
        }
    }

    /// Sets the preferred video stabilization mode on the video data output connection.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setStabilizationMode(_ mode: AVCaptureVideoStabilizationMode) {
        sessionQueue.async { [weak self] in
            guard let connection = self?.videoDataOutput?.connection(with: .video) else { return }
            PRMStabilizationHelper.setPreferredStabilizationMode(mode, on: connection)
        }
    }

    /// Sets the frame rate on the current video device.
    ///
    /// Safe to call from any thread — dispatches to `sessionQueue`.
    public func setFrameRate(_ fps: Float64) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            try? PRMFrameRateHelper.setFrameRate(fps, on: device)
        }
    }

    // MARK: - Device Discovery

    /// Returns the best available video device for the given position.
    ///
    /// Prefers triple → dual → wide angle, matching AnimalVision's selection.
    public func bestAvailableVideoDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
        ]
        #if !os(macOS)
            deviceTypes.insert(contentsOf: [
                .builtInTripleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
            ], at: 0)
        #endif

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position,
        )

        return discoverySession.devices.first
    }

    // MARK: - Observers

    private func addObservers() {
        // KVO: session.isRunning
        let runningObservation = session.observe(\.isRunning, options: .new) { [weak self] _, change in
            guard let self, let isRunning = change.newValue else { return }
            self.isSessionRunning = isRunning
            self.onSessionRunningChanged?(isRunning)
        }
        keyValueObservations.append(runningObservation)

        // Notification: session was interrupted (iOS/Catalyst only)
        #if !os(macOS)
            let interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil,
            ) { [weak self] notification in
                guard let self else { return }
                if let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
                    self.onSessionInterrupted?(reasonValue)
                }
            }
            notificationObservers.append(interruptionObserver)

            // Notification: session interruption ended
            let endedObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil,
            ) { [weak self] _ in
                self?.onSessionInterruptionEnded?()
            }
            notificationObservers.append(endedObserver)
        #endif

        // Notification: runtime error
        let errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil,
        ) { [weak self] notification in
            guard let self else { return }
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                PRMLogger.session.error("Session runtime error: \(error.localizedDescription)")
                self.onSessionRuntimeError?(error)
            }
        }
        notificationObservers.append(errorObserver)

        // Notification: subject area changed (re-center focus)
        #if !os(macOS)
            let subjectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                object: videoDevice,
                queue: nil,
            ) { [weak self] _ in
                guard let self else { return }
                let center = CGPoint(x: 0.5, y: 0.5)
                self.focus(
                    with: .continuousAutoFocus,
                    exposureMode: .continuousAutoExposure,
                    at: center,
                    monitorSubjectAreaChange: false,
                )
            }
            notificationObservers.append(subjectObserver)
        #endif
    }

    private func removeObservers() {
        keyValueObservations.removeAll()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
}
