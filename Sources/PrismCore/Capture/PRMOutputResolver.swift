@preconcurrency import AVFoundation
import os

/// How a capture wrapper (``PRMPhotoCapture``, ``PRMVideoRecorder``) finds its output.
///
/// The output-based initializers bind one output for good. The session-based ones read the
/// session's current output at every capture, because Prism's reconfigure paths (Live Photo
/// recovery after a virtual-device swap, frame-rate format swaps that rebuild the movie
/// output, a photo output re-attach) replace the instance; a wrapper holding the old one
/// would capture against a detached output and fail at the AVFoundation gate.
final class PRMOutputResolver<Output: AVCaptureOutput>: @unchecked Sendable {
    private enum Source: @unchecked Sendable {
        case fixed(Output)
        case dynamic(@Sendable () async -> Output?)
    }

    private let source: Source
    private let latestResolved = OSAllocatedUnfairLock<Output?>(uncheckedState: nil)

    /// Always `output`.
    init(fixed output: Output) {
        source = .fixed(output)
    }

    /// Calls `resolve` at every capture.
    init(resolve: @escaping @Sendable () async -> Output?) {
        source = .dynamic(resolve)
    }

    /// The fixed output, or the one the last ``resolve()`` returned (`nil` before the first
    /// resolution, or when the session had no such output). May be stale for session-based
    /// wrappers; captures always resolve afresh.
    var latest: Output? {
        switch source {
        case let .fixed(output): output
        case .dynamic: latestResolved.withLockUnchecked { $0 }
        }
    }

    /// The output to capture with right now.
    func resolve() async -> Output? {
        switch source {
        case let .fixed(output):
            return output
        case let .dynamic(resolve):
            let output = await resolve()
            latestResolved.withLockUnchecked { $0 = output }
            return output
        }
    }
}
