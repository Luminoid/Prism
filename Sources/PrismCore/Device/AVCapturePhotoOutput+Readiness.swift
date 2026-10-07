@preconcurrency import AVFoundation

// MARK: - Photo output readiness

//
// Shared by `PRMCameraSession.awaitPhotoOutputReady()` (after every begin/commit) and
// `PRMPhotoCapture`'s per-capture pre-flight, so both wait for the same thing.

extension AVCapturePhotoOutput {
    /// What the readiness polls check.
    ///
    /// `captureReadiness` alone isn't enough: it only leaves `.ready` once a capture has been
    /// queued, so it reads `.ready` during a rebuild that hasn't seen a capture yet. The
    /// rebuild does reset `maxPhotoDimensions` to `(0, 0)` and repopulates it when it's done,
    /// so ready means an enabled, active video connection, `.ready`, and non-zero dimensions.
    struct PRMReadiness {
        let hasConnection: Bool
        let isConnectionActive: Bool
        let captureReadiness: AVCapturePhotoOutput.CaptureReadiness
        let maxDimensions: CMVideoDimensions

        var hasDimensions: Bool {
            maxDimensions.width > 0 && maxDimensions.height > 0
        }

        var isReady: Bool {
            isConnectionActive && captureReadiness == .ready && hasDimensions
        }

        /// Public log text naming what's still missing.
        var summary: String {
            let connection = hasConnection ? (isConnectionActive ? "active" : "inactive") : "none"
            return "connection=\(connection), readiness=\(Self.name(of: captureReadiness)), maxDim=\(maxDimensions.width)×\(maxDimensions.height)"
        }

        private static func name(of readiness: AVCapturePhotoOutput.CaptureReadiness) -> String {
            switch readiness {
            case .ready: "ready"
            case .sessionNotRunning: "sessionNotRunning"
            case .notReadyMomentarily: "notReadyMomentarily"
            case .notReadyWaitingForCapture: "notReadyWaitingForCapture"
            case .notReadyWaitingForProcessing: "notReadyWaitingForProcessing"
            @unknown default: "\(readiness.rawValue)"
            }
        }
    }

    /// The output's current readiness.
    var prm_readiness: PRMReadiness {
        let connection = connection(with: .video)
        return PRMReadiness(
            hasConnection: connection != nil,
            isConnectionActive: connection?.isEnabled == true && connection?.isActive == true,
            captureReadiness: captureReadiness,
            maxDimensions: maxPhotoDimensions
        )
    }

    /// Re-applies the largest landscape photo dimensions of the source device's active format
    /// when the connection is back but the ceiling still reads `(0, 0)`. A Live Photo toggle
    /// on a virtual device resets it, and an assignment inside the toggle's own commit can be
    /// rejected while AVFoundation re-validates; a plain assignment afterwards sticks.
    /// Returns the applied dimensions, or `nil` when nothing needed (or allowed) healing.
    @discardableResult
    func prm_healMaxPhotoDimensionsIfNeeded() -> CMVideoDimensions? {
        let readiness = prm_readiness
        guard readiness.isConnectionActive, !readiness.hasDimensions,
              let largest = prm_sourceDevice?.activeFormat.prm_largestLandscapePhotoDimensions
        else { return nil }
        maxPhotoDimensions = largest
        return largest
    }
}

extension AVCaptureOutput {
    /// The video device feeding this output: the first device input on its connections, or
    /// `nil` when the output isn't attached to a session with a camera.
    var prm_sourceDevice: AVCaptureDevice? {
        for connection in connections {
            for port in connection.inputPorts {
                if let deviceInput = port.input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                    return deviceInput.device
                }
            }
        }
        return nil
    }
}

extension AVCaptureDevice.Format {
    /// The largest landscape entry (`width >= height`) of `supportedMaxPhotoDimensions`, by
    /// area. Portrait entries from video formats would otherwise win an area pick on some
    /// models and pin the photo ceiling to a video resolution.
    var prm_largestLandscapePhotoDimensions: CMVideoDimensions? {
        Self.prm_largestLandscape(supportedMaxPhotoDimensions)
    }

    /// Pure core of ``prm_largestLandscapePhotoDimensions``.
    static func prm_largestLandscape(_ dimensions: [CMVideoDimensions]) -> CMVideoDimensions? {
        dimensions
            .filter { $0.width >= $0.height }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
}
