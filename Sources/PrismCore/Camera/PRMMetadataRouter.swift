import AVFoundation

/// `AVCaptureMetadataOutputObjectsDelegate` that converts metadata objects to Sendable
/// ``PRMDetectedObject`` values and fans them out. Owned by ``PRMCameraSession`` (as
/// ``PRMCameraSession/metadataRouter``) and installed on its metadata output, so it survives
/// output rebuilds. Callbacks arrive on ``PRMCameraSession/metadataOutputQueue``.
///
/// `@unchecked Sendable` for the same reason as ``PRMFilterPipeline``: its only mutable
/// state is lock-protected, and AVFoundation calls it from its own queue.
public final class PRMMetadataRouter: NSObject, @unchecked Sendable {
    private let objects = PRMStreamRegistry<[PRMDetectedObject]>(bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock()
    private var latestFocusTracked: PRMDetectedObject?

    override public init() {
        super.init()
    }

    /// Detected objects per metadata callback (roughly once per frame while anything is
    /// detected, then an empty array when everything has left the scene).
    public func detectedObjects() -> AsyncStream<[PRMDetectedObject]> {
        objects.makeStream()
    }

    /// The most recent iOS 27 focus-tracked subject, or `nil` when nothing is tracked.
    /// Used to re-target tracking (AVFoundation stops updating `focusPointOfInterest`
    /// while it tracks).
    public var lastFocusTrackedObject: PRMDetectedObject? {
        lock.lock()
        defer { lock.unlock() }
        return latestFocusTracked
    }

    func publish(_ detected: [PRMDetectedObject]) {
        lock.lock()
        latestFocusTracked = detected.first { $0.kind == .focusTracked }
        lock.unlock()
        objects.yield(detected)
    }

    /// Forgets the last batch and tells subscribers nothing is detected. Called when the
    /// metadata types change or the camera switches: AVFoundation then stops calling the
    /// delegate for the old types, so the last batch (and the tracked subject the bias
    /// re-targets at) would otherwise stay stale.
    func reset() {
        lock.lock()
        latestFocusTracked = nil
        lock.unlock()
        objects.yield([])
    }
}

extension PRMMetadataRouter: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        publish(metadataObjects.map(PRMDetectedObject.init))
    }
}
