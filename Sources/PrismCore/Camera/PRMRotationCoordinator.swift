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
/// - ``previewRotationAngles``: apply to the preview layer/view.
/// - ``captureRotationAngles``: apply to photo/video output connections.
///
/// ```swift
/// let coordinator = PRMRotationCoordinator(device: device, previewLayer: nil)
/// Task {
///     for await angle in coordinator.previewRotationAngles() {
///         previewView.rotationAngle = angle
///     }
/// }
/// ```
@MainActor
public final class PRMRotationCoordinator {
    /// The underlying Apple coordinator. Use this for one-shot angle reads.
    public let coordinator: AVCaptureDevice.RotationCoordinator

    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?

    private var previewContinuations: [UUID: AsyncStream<CGFloat>.Continuation] = [:]
    private var captureContinuations: [UUID: AsyncStream<CGFloat>.Continuation] = [:]

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
        for continuation in previewContinuations.values {
            continuation.finish()
        }
        for continuation in captureContinuations.values {
            continuation.finish()
        }
    }

    // MARK: - Streams

    /// Async stream of rotation angles for the **preview layer**, in degrees.
    public func previewRotationAngles() -> AsyncStream<CGFloat> {
        AsyncStream { continuation in
            let id = UUID()
            previewContinuations[id] = continuation
            // Emit current value immediately.
            continuation.yield(coordinator.videoRotationAngleForHorizonLevelPreview)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.previewContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Async stream of rotation angles for the **capture connection**, in degrees.
    public func captureRotationAngles() -> AsyncStream<CGFloat> {
        AsyncStream { continuation in
            let id = UUID()
            captureContinuations[id] = continuation
            continuation.yield(coordinator.videoRotationAngleForHorizonLevelCapture)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.captureContinuations.removeValue(forKey: id)
                }
            }
        }
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
                guard let self else { return }
                for continuation in self.previewContinuations.values {
                    continuation.yield(angle)
                }
            }
        }

        captureObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for continuation in self.captureContinuations.values {
                    continuation.yield(angle)
                }
            }
        }
    }
}
