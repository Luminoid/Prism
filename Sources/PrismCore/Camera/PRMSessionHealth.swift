import AVFoundation

// MARK: - PRMDeferredStart

/// Which outputs start after the first preview frame instead of with the session (iOS 26
/// deferred start). Deferring the photo and movie outputs gets the preview on screen sooner.
public enum PRMDeferredStart: Sendable, Equatable {
    /// Leave AVFoundation's defaults alone. Apps linked on iOS 26 or later defer the photo
    /// and movie outputs automatically; earlier systems start everything with the session.
    case systemDefault
    /// Start every output with the session, as on iOS 18–25.
    case disabled
    /// Defer the photo and movie outputs explicitly. The video data output always starts
    /// immediately because it feeds the preview.
    case photoAndMovie
}

// MARK: - PRMLensSmudgeStatus

/// Result of iOS 26 camera-lens smudge detection.
public enum PRMLensSmudgeStatus: Sendable, Equatable {
    /// Detection is off, or unsupported on this device / format / OS.
    case disabled
    /// The most recent run found no smudge.
    case clean
    /// The most recent run found the lens smudged.
    case smudged
    /// The result hasn't settled, typically from camera movement or the scene content.
    case unknown

    @available(iOS 26.0, *)
    init(_ status: AVCaptureCameraLensSmudgeDetectionStatus) {
        switch status {
        case .smudgeNotDetected: self = .clean
        case .smudged: self = .smudged
        case .unknown: self = .unknown
        default: self = .disabled
        }
    }
}

// MARK: - PRMLowLightVideoNoiseReduction

/// iOS 27 low-light video noise reduction policy for the movie and video-data connections.
public enum PRMLowLightVideoNoiseReduction: Sendable, Equatable {
    /// The system enables it when the connection supports it (the SDK default for movie
    /// file output connections).
    case automatic
    /// Force it on where supported. Costs additional power.
    case on
    /// Force it off.
    case off
}

// MARK: - PRMSystemPressure

/// Sendable snapshot of `AVCaptureDevice.systemPressureState`.
public struct PRMSystemPressure: Sendable, Equatable {
    /// Pressure level, ordered from normal to "capture must stop".
    public enum Level: Int, Sendable, Comparable {
        case nominal
        case fair
        case serious
        case critical
        case shutdown

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Contributing factors.
    public struct Factors: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The whole system is running hot.
        public static let systemTemperature = Self(rawValue: 1 << 0)
        /// Peak power demand exceeds what the battery can currently supply.
        public static let peakPower = Self(rawValue: 1 << 1)
        /// The depth module is running hot; depth quality may degrade.
        public static let depthModuleTemperature = Self(rawValue: 1 << 2)
        /// The camera module is running hot.
        public static let cameraTemperature = Self(rawValue: 1 << 3)
        /// iOS 27: the device will shut down within 30 seconds unless load drops.
        public static let batteryStress = Self(rawValue: 1 << 4)
    }

    public var level: Level
    public var factors: Factors

    public init(level: Level, factors: Factors = []) {
        self.level = level
        self.factors = factors
    }

    /// No pressure.
    public static let nominal = Self(level: .nominal)

    init(_ state: AVCaptureDevice.SystemPressureState) {
        level = switch state.level {
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        case .shutdown: .shutdown
        default: .nominal
        }
        var factors: Factors = []
        let avFactors = state.factors
        if avFactors.contains(.systemTemperature) { factors.insert(.systemTemperature) }
        if avFactors.contains(.peakPower) { factors.insert(.peakPower) }
        if avFactors.contains(.depthModuleTemperature) { factors.insert(.depthModuleTemperature) }
        if avFactors.contains(.cameraTemperature) { factors.insert(.cameraTemperature) }
        if #available(iOS 27.0, *), avFactors.contains(.batteryStress) { factors.insert(.batteryStress) }
        self.factors = factors
    }
}
