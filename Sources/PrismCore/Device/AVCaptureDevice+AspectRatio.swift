import AVFoundation

public extension AVCaptureDevice {
    /// Current dynamic aspect ratio (iOS 26), or `nil` when unsupported.
    var prm_dynamicAspectRatio: PRMAspectRatio? {
        guard #available(iOS 26.0, *), let ratio = dynamicAspectRatio else { return nil }
        return PRMAspectRatio(ratio)
    }

    /// Output dimensions for the current dynamic aspect ratio (iOS 26), or `nil` when
    /// unsupported.
    var prm_dynamicDimensions: PRMVideoDimensions? {
        guard #available(iOS 26.0, *) else { return nil }
        let dimensions = PRMVideoDimensions(dynamicDimensions)
        return dimensions.isEmpty ? nil : dimensions
    }

    /// Sets the dynamic aspect ratio (iOS 26) and waits for the first buffer that has it.
    /// Returns that buffer's device-clock timestamp.
    ///
    /// The confirmation needs a running session: with no frames flowing it never comes, so
    /// the wait gives up after `timeout` seconds.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` when the active format
    ///   doesn't list `ratio` or no frame confirms the change in time, or AVFoundation's
    ///   own error.
    @available(iOS 26.0, *)
    func prm_setDynamicAspectRatio(_ ratio: PRMAspectRatio, timeout: TimeInterval = 2) async throws -> CMTime {
        let avRatio = ratio.avAspectRatio
        guard activeFormat.supportedDynamicAspectRatios.contains(avRatio) else {
            throw PRMSessionError.unsupportedConfiguration("The active format doesn't support \(ratio.rawValue)")
        }
        // Lock, start the change, unlock, then wait: holding the device lock across the
        // wait would stall every other configuration call until a frame arrives.
        return try await Self.prm_awaitDeviceCommit(
            timeout: timeout,
            timeoutMessage: "No frame confirmed the \(ratio.rawValue) aspect ratio within \(Int(timeout)) s"
        ) { resume in
            try prm_withConfigurationLock {
                setDynamicAspectRatio(avRatio) { time, error in
                    resume(error.map { .failure($0) } ?? .success(time))
                }
            }
        }
    }
}
