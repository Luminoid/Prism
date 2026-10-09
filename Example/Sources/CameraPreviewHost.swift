@preconcurrency import AVFoundation
import PrismCore
import PrismUI

// MARK: - CameraPreviewHostDelegate

/// What a camera screen supplies to ``CameraPreviewHost``: its configuration, its setup once
/// configured, and what to do with the camera's state, errors and interruptions.
@MainActor
protocol CameraPreviewHostDelegate: AnyObject {
    /// Configures the camera for this screen: `PRMCamera.configure(_:)` plus anything that
    /// must land before the session starts. Throwing ends the boot, and
    /// ``cameraHost(_:didFailToConfigure:)`` reports it.
    func cameraHostConfigure(_ host: CameraPreviewHost) async throws
    /// Screen setup after a successful configure, before the streams start and the session
    /// runs: capture wrappers, the drawer, depth outputs.
    func cameraHostDidConfigure(_ host: CameraPreviewHost) async
    /// The session is running: after the first boot, and after every
    /// ``CameraPreviewHost/reconfigure()``.
    func cameraHostDidStart(_ host: CameraPreviewHost) async
    func cameraHost(_ host: CameraPreviewHost, didFailToConfigure error: any Error)
    func cameraHost(_ host: CameraPreviewHost, didReceive error: PRMSessionError)
    func cameraHost(_ host: CameraPreviewHost, didUpdate state: PRMCameraState)
    func cameraHost(_ host: CameraPreviewHost, didChangeInterruption interrupted: Bool)
    /// The host set ``CameraPreviewHost/previewView``'s rotation and mirroring for a new
    /// device, for a screen that draws the same frames elsewhere too (the Depth Inspector's
    /// depth tile).
    func cameraHost(_ host: CameraPreviewHost, didOrientPreview rotation: PRMPreviewView.Rotation, mirroring: Bool)
}

extension CameraPreviewHostDelegate {
    func cameraHostDidConfigure(_: CameraPreviewHost) async {}
    func cameraHostDidStart(_: CameraPreviewHost) async {}
    func cameraHost(_: CameraPreviewHost, didUpdate _: PRMCameraState) {}
    func cameraHost(_: CameraPreviewHost, didChangeInterruption _: Bool) {}
    func cameraHost(_: CameraPreviewHost, didOrientPreview _: PRMPreviewView.Rotation, mirroring _: Bool) {}
}

// MARK: - CameraPreviewHost

/// The camera, filter pipeline and Metal preview behind each camera demo, with the lifecycle
/// every screen needs:
///
/// - **Boot** runs once, from the first `viewWillAppear`: permissions, the screen's
///   configure and setup, the preview wiring, the streams, then `start()`. It's a stored task
///   that checks for cancellation before wiring streams and before starting the session, so
///   a screen dismissed mid-boot never leaves the camera running.
/// - **Appear / disappear**: `start()` on every later appear, `stop()` from
///   `viewDidDisappear`. Stopping on *did* disappear means a back swipe the user cancels keeps
///   the preview live. Lifecycle steps run one after another, so a stop can't overtake the
///   start before it.
/// - **Streams** (state, errors, interruptions, an optional state poll, a screen's own loops
///   and the rotation angles) run while the screen is visible, capture the host weakly and
///   end on disappear and in `deinit`.
@MainActor
final class CameraPreviewHost {
    // MARK: - Properties

    let camera = PRMCamera()
    let pipeline = PRMFilterPipeline()
    let renderContext: PRMRenderContext
    let previewView: PRMPreviewView
    weak var delegate: (any CameraPreviewHostDelegate)?

    /// Whether the camera has been configured and started at least once.
    private(set) var isBooted = false
    /// The coordinator for the session's current device. Rebound by
    /// ``rebindRotationCoordinator()`` after every device change.
    private(set) var rotationCoordinator: PRMRotationCoordinator?
    /// The gravity-aligned angle for stills and recordings, from the coordinator's capture
    /// stream: pass it as ``PRMPhotoSettings/rotationAngle`` or to
    /// `PRMVideoRecorder.start(rotationAngle:)` so landscape captures save upright. Portrait
    /// (90°) until the first angle arrives.
    private(set) var captureRotationAngle: CGFloat = 90

    private let requestsMicrophone: Bool
    private let statePollInterval: Duration?
    private var loops: [@MainActor () async -> Void] = []
    private var isVisible = false
    /// The latest boot, start, stop or reconfigure step; each step waits for the one before.
    private var lifecycleTask: Task<Void, Never>?
    /// The boot step, cancelled on disappear and in `deinit`. A stop step is never cancelled:
    /// it has to run even when the screen is already gone.
    private var bootTask: Task<Void, Never>?
    private var streamTasks: [Task<Void, Never>] = []
    private var rotationTasks: [Task<Void, Never>] = []

    // MARK: - Init

    /// - Parameters:
    ///   - name: Names the render context (Metal debugging labels).
    ///   - requestsMicrophone: Ask for microphone access at boot, for screens that record.
    ///   - statePollInterval: Re-read the device state this often while visible. Auto exposure
    ///     and white balance drift without going through a setter, so a live readout needs it.
    init(name: String, requestsMicrophone: Bool = false, statePollInterval: Duration? = nil) {
        renderContext = Self.makeRenderContext(name: name)
        previewView = PRMPreviewView(context: renderContext)
        self.requestsMicrophone = requestsMicrophone
        self.statePollInterval = statePollInterval
    }

    deinit {
        bootTask?.cancel()
        for task in streamTasks + rotationTasks {
            task.cancel()
        }
    }

    /// `PRMRenderContext(name:)` fails only on a device without Metal, which the Metal-backed
    /// preview can't run on at all. There's no fallback to offer, so the demo stops here.
    static func makeRenderContext(name: String) -> PRMRenderContext {
        guard let context = PRMRenderContext(name: name) else {
            fatalError("Metal is unavailable on this device; the Prism preview requires Metal.")
        }
        return context
    }

    // MARK: - Lifecycle

    /// Call from `viewWillAppear(_:)`: boots the camera the first time, restarts it after a
    /// disappearance.
    func viewWillAppear() {
        guard !isVisible else { return }
        isVisible = true
        if isBooted {
            startStreams()
            enqueue { [camera] in await camera.start() }
        } else {
            bootTask = enqueue { [weak self] in await self?.boot() }
        }
    }

    /// Call from `viewDidDisappear(_:)`. Cancels an unfinished boot, ends the streams, and
    /// stops the camera once `pending` work is done (a capture being saved, a recording being
    /// finished).
    func viewDidDisappear(awaiting pending: [Task<Void, Never>] = []) {
        guard isVisible else { return }
        isVisible = false
        lifecycleTask?.cancel()
        stopStreams()
        enqueue { [camera] in
            for task in pending {
                await task.value
            }
            await camera.stop()
        }
    }

    /// Stops the camera, then configures and starts it again (the Configuration Lab's Apply).
    /// Returns once it's running again, or once the configure failed or the screen left.
    func reconfigure() async {
        let step = enqueue { [weak self] in
            guard let self else { return }
            await camera.stop()
            await configureAndStart()
        }
        await step.value
    }

    /// Adds a loop that runs while the screen is visible and the camera is booted, like the
    /// built-in streams. Register loops before the first appearance.
    func addLoop(_ body: @escaping @MainActor () async -> Void) {
        loops.append(body)
        if !streamTasks.isEmpty {
            streamTasks.append(Task { await body() })
        }
    }

    // MARK: - Rotation

    /// Binds a fresh rotation coordinator to the session's current device and orients the
    /// preview for it. Call after every device change; the host calls it after each configure.
    ///
    /// The data-output connection keeps AVFoundation's default rotation, so texture space is
    /// the device's point-of-interest space (tap-to-focus and detection outlines map through
    /// ``PRMPreviewView`` directly), and the preview view does the rest of the rotation and
    /// the front camera's mirroring.
    func rebindRotationCoordinator() async {
        stopRotationStreams()
        rotationCoordinator = nil
        guard let device = await camera.session.videoDevice else { return }
        let coordinator = PRMRotationCoordinator(device: device, previewLayer: previewView.layer)
        rotationCoordinator = coordinator
        let connectionAngle = await camera.session.videoDataRotationAngle
        let dataMirrored = await camera.session.isVideoDataMirrored
        orientPreview(for: device, coordinator: coordinator, connectionAngle: connectionAngle, dataMirrored: dataMirrored)
        if !streamTasks.isEmpty {
            startRotationStreams()
        }
    }

    /// Every demo screen is portrait-only, so the preview rotates frames by what makes them
    /// upright in portrait minus what the data connection already applied. The two differ by
    /// camera: the Center Stage front camera (iPhone 17 and later) is mounted in portrait and
    /// upright at 0°, but its connection defaults to 270° so frames look like older front
    /// cameras', which leaves 90° to draw, as on every other camera. The front camera's
    /// mirroring happens after the rotation, in view space, like a mirror.
    private func orientPreview(for device: AVCaptureDevice, coordinator: PRMRotationCoordinator, connectionAngle: CGFloat?, dataMirrored: Bool?) {
        let angle = coordinator.portraitFrameRotation(connectionAngle: connectionAngle ?? 0)
        let rotation = PRMPreviewView.Rotation(angle: angle)
        let mirroring = device.position == .front
        previewView.rotation = rotation
        previewView.mirroring = mirroring
        var upright = "n/a"
        if #available(iOS 27.0, *) {
            upright = "\(Int(coordinator.videoRotationAngle(relativeTo: .portrait)))"
        }
        let camera = "\(device.deviceType.rawValue) position \(device.position.rawValue)"
        let angles = [
            "portrait angle \(upright)",
            "coordinator preview \(Int(coordinator.currentPreviewRotationAngle))",
            "capture \(Int(coordinator.currentCaptureRotationAngle))",
            "data connection \(connectionAngle.map { "\(Int($0))°" } ?? "n/a")",
            "mirrored \(dataMirrored.map(String.init) ?? "n/a")",
        ].joined(separator: ", ")
        ExampleLog.session.debug(
            "Preview orientation: \(camera, privacy: .public) → \(Int(rotation.rawValue))° mirrored=\(mirroring) (\(angles, privacy: .public))"
        )
        delegate?.cameraHost(self, didOrientPreview: rotation, mirroring: mirroring)
    }

    // MARK: - Boot

    @discardableResult
    private func enqueue(_ step: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { [previous = lifecycleTask] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await step()
        }
        lifecycleTask = task
        return task
    }

    private func boot() async {
        if PRMPermissions.cameraStatus() == .notDetermined {
            _ = await PRMPermissions.requestCameraAccess()
        }
        if requestsMicrophone, PRMPermissions.microphoneStatus() == .notDetermined {
            _ = await PRMPermissions.requestMicrophoneAccess()
        }
        await configureAndStart()
    }

    private func configureAndStart() async {
        guard !Task.isCancelled, let delegate else { return }
        do {
            try await delegate.cameraHostConfigure(self)
        } catch {
            isBooted = false
            if !Task.isCancelled {
                delegate.cameraHost(self, didFailToConfigure: error)
            }
            return
        }
        guard !Task.isCancelled else { return }
        await attachPreview()
        await rebindRotationCoordinator()
        await delegate.cameraHostDidConfigure(self)
        guard !Task.isCancelled, isVisible else { return }
        isBooted = true
        startStreams()
        await camera.start()
        guard !Task.isCancelled else { return }
        await delegate.cameraHostDidStart(self)
    }

    private func attachPreview() async {
        pipeline.isEnabled = true
        // Frames arrive on the session's data-output queue. The closure is `@Sendable`, so it
        // can't touch main-actor state there; it reaches the view only through the sink, whose
        // one call, `update(_:)`, is nonisolated and lock-protected.
        let sink = PreviewFrameSink(view: previewView)
        pipeline.onFrame = { @Sendable frame in
            sink.update(frame.pixelBuffer)
        }
        await camera.session.setVideoDataOutputDelegate(pipeline)
    }

    // MARK: - Streams

    private func startStreams() {
        guard isVisible, streamTasks.isEmpty else { return }
        streamTasks = [
            Task { [weak self, camera] in
                for await state in camera.stateStream() {
                    self?.forward(state: state)
                }
            },
            Task { [weak self, camera] in
                for await error in camera.errorStream() {
                    self?.forward(error: error)
                }
            },
            Task { [weak self, camera] in
                for await interrupted in camera.interruptionStream() {
                    self?.forward(interrupted: interrupted)
                }
            },
        ]
        if let statePollInterval {
            streamTasks.append(Task { [camera] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: statePollInterval)
                    guard !Task.isCancelled else { return }
                    await camera.refreshState()
                }
            })
        }
        for loop in loops {
            streamTasks.append(Task { await loop() })
        }
        startRotationStreams()
    }

    private func stopStreams() {
        for task in streamTasks {
            task.cancel()
        }
        streamTasks.removeAll()
        stopRotationStreams()
    }

    private func startRotationStreams() {
        guard rotationTasks.isEmpty, let coordinator = rotationCoordinator else { return }
        rotationTasks = [
            Task { [weak self] in
                for await angle in coordinator.captureRotationAngles() {
                    self?.captureRotationAngle = angle
                }
            },
        ]
    }

    private func stopRotationStreams() {
        for task in rotationTasks {
            task.cancel()
        }
        rotationTasks.removeAll()
    }

    private func forward(state: PRMCameraState) {
        delegate?.cameraHost(self, didUpdate: state)
    }

    private func forward(error: PRMSessionError) {
        delegate?.cameraHost(self, didReceive: error)
    }

    private func forward(interrupted: Bool) {
        delegate?.cameraHost(self, didChangeInterruption: interrupted)
    }
}

/// The preview as the data-output queue sees it: a weak reference used only for
/// `PRMPreviewView.update(_:)`, which is nonisolated and lock-protected.
private final class PreviewFrameSink: @unchecked Sendable {
    private weak var view: PRMPreviewView?

    init(view: PRMPreviewView) {
        self.view = view
    }

    func update(_ pixelBuffer: CVPixelBuffer) {
        view?.update(pixelBuffer)
    }
}
