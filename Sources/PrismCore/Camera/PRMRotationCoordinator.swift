import AVFoundation

#if canImport(UIKit)
    import UIKit
#endif

/// Bridges `AVCaptureDevice.RotationCoordinator` (iOS 17+) to async streams.
///
/// `RotationCoordinator` is Apple's preferred replacement for the deprecated
/// `videoOrientation`/`UIDeviceOrientation` mapping. It uses device motion to compute
/// gravity-aligned rotation angles for both the preview layer and capture connections,
/// independent of interface orientation.
///
/// Two angles are exposed as `AsyncStream<CGFloat>`:
/// - ``previewRotationAngles()``: apply to an `AVCaptureVideoPreviewLayer`'s connection.
/// - ``captureRotationAngles()``: apply to photo/video output connections (for stills,
///   pass ``currentCaptureRotationAngle`` as ``PRMPhotoSettings/rotationAngle``).
///
/// Both are absolute connection angles, measured from the camera's native sensor
/// orientation. A view that draws video-data frames itself rotates by what the frames'
/// connection hasn't already applied: ``portraitFrameRotation(connectionAngle:)``.
///
/// ```swift
/// let coordinator = PRMRotationCoordinator(device: device, previewLayer: previewView.layer)
/// let connectionAngle = await session.videoDataRotationAngle ?? 0
/// previewView.rotation = PRMPreviewView.Rotation(angle: coordinator.portraitFrameRotation(connectionAngle: connectionAngle))
/// ```
@MainActor
public final class PRMRotationCoordinator {
    /// The underlying Apple coordinator. Use this for one-shot angle reads.
    public let coordinator: AVCaptureDevice.RotationCoordinator

    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?

    private let previewAngles = PRMStreamRegistry<CGFloat>()
    private let captureAngles = PRMStreamRegistry<CGFloat>()

    /// Creates a rotation coordinator for the given device. Pass the preview layer (if any)
    /// so the system can rotate it automatically — otherwise pass `nil` and apply the angle
    /// from the stream yourself.
    public init(device: AVCaptureDevice, previewLayer: CALayer?) {
        coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        observeAngles()
    }

    deinit {
        previewObservation?.invalidate()
        captureObservation?.invalidate()
        // Registry `deinit` finishes its own subscribers; no explicit teardown needed.
    }

    // MARK: - Streams

    /// Async stream of rotation angles for the **preview layer**, in degrees.
    public func previewRotationAngles() -> AsyncStream<CGFloat> {
        previewAngles.makeStream(initial: coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    /// Async stream of rotation angles for the **capture connection**, in degrees.
    public func captureRotationAngles() -> AsyncStream<CGFloat> {
        captureAngles.makeStream(initial: coordinator.videoRotationAngleForHorizonLevelCapture)
    }

    // MARK: - One-shot angle reads

    /// Current preview rotation angle in degrees.
    public var currentPreviewRotationAngle: CGFloat {
        coordinator.videoRotationAngleForHorizonLevelPreview
    }

    /// Current capture rotation angle in degrees.
    public var currentCaptureRotationAngle: CGFloat {
        coordinator.videoRotationAngleForHorizonLevelCapture
    }

    /// The fixed rotation (degrees) that makes this camera's output upright for a given
    /// device orientation, regardless of how the device is held right now (iOS 27). Unlike
    /// the horizon-level angles above, it doesn't follow gravity: use it for UIs locked to
    /// one orientation. External cameras return 0.
    @available(iOS 27.0, *)
    public func videoRotationAngle(relativeTo orientation: AVCaptureVideoOrientation) -> CGFloat {
        coordinator.videoRotationAngleRelative(toDeviceOrientation: orientation)
    }

    // MARK: - Drawing frames yourself

    /// Clockwise degrees to rotate frames by so they're upright in a portrait interface,
    /// when they come from a connection already rotated by `connectionAngle` (its
    /// `videoRotationAngle`, such as ``PRMCameraSession/videoDataRotationAngle``).
    ///
    /// The coordinator's angles are measured from the camera's native sensor orientation,
    /// but a connection's default isn't always 0: the Center Stage front camera of iPhone 17
    /// and later defaults to 270°. The rotation left to draw is the difference, which comes
    /// to 90° for every iPhone camera while its connection keeps its default.
    ///
    /// The upright angle is iOS 27's per-camera ``videoRotationAngle(relativeTo:)``. Before
    /// iOS 27 it's the horizon-level preview angle, which follows the preview layer's
    /// interface orientation, so create the coordinator with the layer the frames are drawn
    /// in. While that layer isn't in a window, this assumes the iPhone layout: 90° past the
    /// connection's default.
    public func portraitFrameRotation(connectionAngle: CGFloat) -> CGFloat {
        let upright: CGFloat
        if #available(iOS 27.0, *) {
            upright = videoRotationAngle(relativeTo: .portrait)
        } else if isPreviewLayerInWindow {
            upright = currentPreviewRotationAngle
        } else {
            return 90
        }
        return Self.frameRotation(uprightAngle: upright, connectionAngle: connectionAngle)
    }

    /// `uprightAngle - connectionAngle`, in `0 ..< 360`: the rotation still to apply to frames
    /// a connection already rotated by `connectionAngle`.
    public nonisolated static func frameRotation(uprightAngle: CGFloat, connectionAngle: CGFloat) -> CGFloat {
        let difference = (uprightAngle - connectionAngle).truncatingRemainder(dividingBy: 360)
        return difference < 0 ? difference + 360 : difference
    }

    /// Whether the coordinator's preview layer is in a window: before that,
    /// `videoRotationAngleForHorizonLevelPreview` reads 0.
    private var isPreviewLayerInWindow: Bool {
        #if canImport(UIKit)
            var layer = coordinator.previewLayer
            while let current = layer {
                if let view = current.delegate as? UIView {
                    return view.window != nil
                }
                layer = current.superlayer
            }
            return false
        #else
            return coordinator.previewLayer != nil
        #endif
    }

    // MARK: - Private

    private func observeAngles() {
        // Same fire-and-forget Task pattern as PRMCamera — see comment there. Each Task body
        // is a single MainActor hop to fan out to subscribers; storing the handles would only
        // add overhead. KVO observations are invalidated in `deinit`, so no new tasks are
        // spawned after teardown.
        previewObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.previewAngles.yield(angle)
            }
        }

        captureObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.captureAngles.yield(angle)
            }
        }
    }
}
