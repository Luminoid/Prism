import AVFoundation

// MARK: - PRMExposureValue

/// One axis of an iOS 27 custom exposure request
/// (`AVCaptureDevice.setExposureModeCustom(lensAperture:duration:iso:completionHandler:)`).
///
/// Each axis is either locked to an explicit value, locked to whatever it currently is, or
/// left to the auto-exposure system. Mixing locked and auto axes gives the "priority" modes
/// (shutter priority = shutter `.fixed`, aperture and ISO `.auto`). Not every combination is
/// supported by every format; `AVCaptureDevice.prm_supportsExposure(aperture:shutterSeconds:iso:)`
/// validates one before it's applied.
public enum PRMExposureValue<Value: Sendable & Equatable>: Sendable, Equatable {
    /// The auto-exposure system keeps managing this axis to hold image brightness.
    case auto
    /// Lock the axis at its current value. Preferable to reading the property and passing it
    /// back, since auto exposure may be changing it while the command is in flight.
    case current
    /// Lock the axis at an explicit value. Clamped to the active format's supported range.
    case fixed(Value)

    /// The explicit value when the axis is `.fixed`, otherwise `nil`.
    public var fixedValue: Value? {
        if case let .fixed(value) = self { value } else { nil }
    }

    /// Whether the auto-exposure system manages this axis.
    public var isAuto: Bool {
        self == .auto
    }
}

extension PRMExposureValue where Value: Comparable {
    /// The same axis with a `.fixed` value clamped into `range` (unchanged when `nil`).
    func clamped(to range: ClosedRange<Value>?) -> Self {
        guard case let .fixed(value) = self, let range else { return self }
        return .fixed(min(max(value, range.lowerBound), range.upperBound))
    }
}

// MARK: - PRMExposureAxes

/// A set of exposure axes. ``PRMCameraState/autoExposureAxes`` reports which axes the
/// auto-exposure system is currently driving: all three in the auto exposure modes, none in
/// full manual, and a subset in an iOS 27 priority mode.
public struct PRMExposureAxes: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Lens aperture (𝑓-number). Fixed on every iPhone before variable-aperture hardware.
    public static let aperture = Self(rawValue: 1 << 0)
    /// Exposure duration (shutter speed).
    public static let shutter = Self(rawValue: 1 << 1)
    /// Sensor gain (ISO).
    public static let iso = Self(rawValue: 1 << 2)
    /// Every axis.
    public static let all: Self = [.aperture, .shutter, .iso]

    /// Builds the set from per-axis "is auto" flags, as reported by iOS 27's
    /// `automaticallyAdjustsLensAperture` / `…ExposureDuration` / `…ISO`.
    public init(apertureAuto: Bool, shutterAuto: Bool, isoAuto: Bool) {
        var axes: Self = []
        if apertureAuto { axes.insert(.aperture) }
        if shutterAuto { axes.insert(.shutter) }
        if isoAuto { axes.insert(.iso) }
        self = axes
    }

    /// The auto axes implied by an exposure mode on systems without per-axis reporting
    /// (before iOS 27): every axis in the auto modes, none in `.custom` or `.locked`.
    public init(exposureMode: AVCaptureDevice.ExposureMode) {
        switch exposureMode {
        case .autoExpose, .continuousAutoExposure: self = .all
        default: self = []
        }
    }
}

// MARK: - PRMExposureSignal

/// Scene characteristics the iOS 27 auto-exposure system can weigh when it picks an aperture
/// or shutter speed. Mirrors `AVCaptureDeviceExposureSignal` as a Sendable value type.
public enum PRMExposureSignal: String, Sendable, CaseIterable, Hashable {
    /// Close the aperture or shorten the exposure to reduce motion blur.
    case subjectMotion
    /// Close the aperture for more depth of field when several faces are in frame.
    case groupPhoto
    /// Close the aperture to sharpen text.
    case document
    /// Open the aperture to avoid diffraction artifacts around point lights.
    case starburst
    /// Adjust the aperture so the exposure duration avoids artificial-light flicker.
    case flicker
}

@available(iOS 27.0, *)
extension PRMExposureSignal {
    init?(_ signal: AVCaptureDeviceExposureSignal) {
        switch signal {
        case .subjectMotion: self = .subjectMotion
        case .groupPhoto: self = .groupPhoto
        case .document: self = .document
        case .starburst: self = .starburst
        case .flicker: self = .flicker
        default: return nil
        }
    }

    var avSignal: AVCaptureDeviceExposureSignal {
        switch self {
        case .subjectMotion: .subjectMotion
        case .groupPhoto: .groupPhoto
        case .document: .document
        case .starburst: .starburst
        case .flicker: .flicker
        }
    }

    static func set(from signals: Set<AVCaptureDeviceExposureSignal>) -> Set<Self> {
        Set(signals.compactMap(Self.init))
    }
}
