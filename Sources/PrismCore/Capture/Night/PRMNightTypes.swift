import AVFoundation
import Foundation

/// What a Night capture should do. See ``PRMNightModeCapture``.
public struct PRMNightModeOptions: Sendable, Equatable {
    /// How long to gather light.
    public enum Duration: Sendable, Equatable {
        /// Picked from how dark the scene is, like the system Camera: 1 to 3 s handheld, 3 to
        /// 10 s when ``PRMNightModeOptions/isStable``.
        case automatic
        /// A fixed time, clamped to 0.5...30 s.
        case seconds(Double)
    }

    public var duration: Duration
    /// The phone is braced or on a tripod (the app decides, typically from the gyroscope):
    /// allows longer frames and a longer automatic duration.
    public var isStable: Bool
    /// `.hevc` encodes HEIF; anything else (or `nil`) JPEG.
    public var codec: AVVideoCodecType?
    /// Rotation for the saved photo in degrees, as for the photo output's connection
    /// (``PRMRotationCoordinator/currentCaptureRotationAngle``). `nil` keeps the photo
    /// connection's current angle.
    public var rotationAngle: CGFloat?

    public init(
        duration: Duration = .automatic,
        isStable: Bool = false,
        codec: AVVideoCodecType? = nil,
        rotationAngle: CGFloat? = nil
    ) {
        self.duration = duration
        self.isStable = isStable
        self.codec = codec
        self.rotationAngle = rotationAngle
    }
}

/// How a Night capture exposes: per-frame shutter and ISO, how long, and how many frames to
/// merge at most.
public struct PRMNightPlan: Sendable, Equatable {
    /// Capture time in seconds.
    public var duration: Double
    /// Shutter per frame, in seconds.
    public var frameDuration: Double
    /// ISO per frame.
    public var iso: Float
    /// The most frames merged; capture stops once this many arrive or `duration` passes.
    public var frameCount: Int

    public init(duration: Double, frameDuration: Double, iso: Float, frameCount: Int) {
        self.duration = duration
        self.frameDuration = frameDuration
        self.iso = iso
        self.frameCount = frameCount
    }
}

/// Progress of a Night capture, for a countdown and a "processing" state.
public struct PRMNightProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Gathering frames: hold still.
        case capturing
        /// Merging and encoding; the camera is already back to normal.
        case processing
    }

    public var phase: Phase
    /// Seconds since capture began.
    public var elapsed: Double
    /// Planned capture time in seconds.
    public var duration: Double
    /// Frames merged so far.
    public var mergedFrames: Int
    /// Planned frame count.
    public var plannedFrames: Int

    public init(phase: Phase, elapsed: Double, duration: Double, mergedFrames: Int, plannedFrames: Int) {
        self.phase = phase
        self.elapsed = elapsed
        self.duration = duration
        self.mergedFrames = mergedFrames
        self.plannedFrames = plannedFrames
    }

    /// Seconds left in the capture phase, rounded up (a "3, 2, 1" countdown); 0 once processing.
    public var secondsRemaining: Int {
        guard phase == .capturing else { return 0 }
        return max(0, Int((duration - elapsed).rounded(.up)))
    }
}

/// A finished Night photo: encoded image data plus what went into it.
public struct PRMNightPhoto: @unchecked Sendable {
    /// HEIF or JPEG data, upright, with EXIF.
    public let data: Data
    /// The EXIF and TIFF dictionaries written into `data`.
    public let metadata: [String: Any]
    public let plan: PRMNightPlan
    /// Frames that went into the merge (the reference included).
    public let mergedFrameCount: Int
    /// Brightening applied after the merge, in EV.
    public let gainEV: Float
    public let timestamp: Date

    public init(data: Data, metadata: [String: Any], plan: PRMNightPlan, mergedFrameCount: Int, gainEV: Float, timestamp: Date = Date()) {
        self.data = data
        self.metadata = metadata
        self.plan = plan
        self.mergedFrameCount = mergedFrameCount
        self.gainEV = gainEV
        self.timestamp = timestamp
    }
}
