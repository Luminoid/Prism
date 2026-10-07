@preconcurrency import AVFoundation

/// The video-data output's sample-buffer delegate. Forwards every callback to the app's
/// delegate (``PRMCameraSession/setVideoDataOutputDelegate(_:)``) and hands each frame to
/// Prism's own observers (``PRMNightModeCapture`` stacks frames from the live stream), so
/// the app's preview keeps running while Prism reads the same frames.
///
/// Callbacks arrive on ``PRMCameraSession/dataOutputQueue``. Observers run there after the
/// app's delegate and must return quickly: holding the queue stalls the preview, and holding
/// a sample buffer past the callback starves the output's buffer pool.
final class PRMVideoFrameRouter: NSObject, @unchecked Sendable {
    typealias Observer = @Sendable (CMSampleBuffer) -> Void

    private let lock = NSLock()
    private var downstream: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
    private var observers: [UUID: Observer] = [:]

    /// The app's delegate. Kept strongly so a full reconfigure (a fresh output instance) can
    /// re-install the router without the app setting its delegate again.
    func setDownstream(_ delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?) {
        lock.lock()
        downstream = delegate
        lock.unlock()
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PRMVideoFrameRouter: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let downstream = downstream
        lock.unlock()
        downstream?.captureOutput?(output, didOutput: sampleBuffer, from: connection)
        notifyObservers(sampleBuffer)
    }

    /// Hands `sampleBuffer` to every observer, after the app's delegate had it.
    func notifyObservers(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let observers = Array(observers.values)
        lock.unlock()
        for observer in observers {
            observer(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let downstream = downstream
        lock.unlock()
        downstream?.captureOutput?(output, didDrop: sampleBuffer, from: connection)
    }
}
