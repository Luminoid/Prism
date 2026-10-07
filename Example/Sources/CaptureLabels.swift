@preconcurrency import AVFoundation
import PrismCore

// MARK: - CaptureLabels

/// Formatting shared by Studio, its drawer and the Configuration Lab.
enum CaptureLabels {
    /// "1/250s" below a second, "2.0s" from a second up, "n/a" for a zero, negative or
    /// non-finite duration.
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "n/a" }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        // Capped so a denormal duration can't overflow `Int`.
        let denominator = min((1 / seconds).rounded(), 1_000_000)
        return "1/\(Int(denominator))s"
    }

    /// "24mm", or "—" when there's no finite focal length to show.
    static func focalLength(_ millimeters: Double) -> String {
        guard millimeters.isFinite, millimeters > 0 else { return "—" }
        return "\(Int(millimeters.rounded()))mm"
    }
}

// MARK: - StabilizationOption

/// Video stabilization choices in one order, with one set of labels, for Studio's drawer and
/// the Configuration Lab.
enum StabilizationOption: CaseIterable {
    case auto, off, standard, cinematic, lowLatency

    /// The options this OS offers (`.lowLatency` is iOS 26+).
    static var available: [Self] {
        if #available(iOS 26.0, *) {
            return allCases
        }
        return allCases.filter { $0 != .lowLatency }
    }

    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .auto: return .auto
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .lowLatency:
            if #available(iOS 26.0, *) { return .lowLatency }
            return .auto
        }
    }

    /// Segment title.
    var label: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .standard: "Std"
        case .cinematic: "Cinem"
        case .lowLatency: "LowLat"
        }
    }

    /// Row value text.
    var name: String {
        switch self {
        case .auto: "auto"
        case .off: "off"
        case .standard: "standard"
        case .cinematic: "cinematic"
        case .lowLatency: "low latency"
        }
    }

    /// Short name of the mode a connection actually runs (`activeVideoStabilizationMode`).
    static func activeName(of mode: AVCaptureVideoStabilizationMode) -> String {
        if #available(iOS 26.0, *), mode == .lowLatency {
            return "low latency"
        }
        return switch mode {
        case .off: "off"
        case .standard: "standard"
        case .cinematic: "cinematic"
        case .cinematicExtended, .cinematicExtendedEnhanced: "cinematic ext"
        case .previewOptimized: "preview"
        case .auto: "auto"
        default: "mode \(mode.rawValue)"
        }
    }
}

// MARK: - CameraCapability

/// The iOS 26 / 27 capabilities ``PRMCameraDevice`` reports, with one set of strings: the
/// Configuration Lab lists the supported ones after Apply, and Studio's drawer explains a
/// disabled row with ``unavailableMessage(for:)``.
enum CameraCapability: CaseIterable {
    case variableAperture
    case exposureSignals
    case lensLock
    case focusRect
    case exposureRect
    case subjectTracking
    case smudgeDetection
    case lowLightNoiseReduction
    case cinematicVideo
    case dynamicAspectRatio
    case smartFraming

    /// Short name in the Configuration Lab's support summary.
    var name: String {
        switch self {
        case .variableAperture: "aperture"
        case .exposureSignals: "AE signals"
        case .lensLock: "lens lock"
        case .focusRect: "focus rect"
        case .exposureRect: "exposure rect"
        case .subjectTracking: "AF tracking"
        case .smudgeDetection: "smudge detection"
        case .lowLightNoiseReduction: "low-light NR"
        case .cinematicVideo: "Cinematic Video"
        case .dynamicAspectRatio: "aspect"
        case .smartFraming: "Smart Framing"
        }
    }

    /// What the capability needs, completing "<feature> needs …".
    var requirement: String {
        switch self {
        case .variableAperture: "iOS 27 and a variable-aperture camera"
        case .exposureSignals: "iOS 27 and a supporting camera"
        case .lensLock: "iOS 27 and a multi-lens camera"
        case .focusRect, .exposureRect: "iOS 26 and a supporting camera"
        case .subjectTracking: "iOS 27 and a supporting format"
        case .smudgeDetection: "iOS 26 and a supporting format"
        case .lowLightNoiseReduction: "iOS 27 and a supporting format"
        case .cinematicVideo: "iOS 26 and a supporting camera"
        case .dynamicAspectRatio, .smartFraming: "iOS 26 and the iPhone 17 front camera"
        }
    }

    /// The toast for a drawer row that needs this capability, e.g. "Lens lock needs iOS 27
    /// and a multi-lens camera".
    func unavailableMessage(for feature: String) -> String {
        "\(feature) needs \(requirement)"
    }

    func isSupported(by device: PRMCameraDevice) -> Bool {
        switch self {
        case .variableAperture: device.apertureRange != nil
        case .exposureSignals: !device.supportedExposureSignals.isEmpty
        case .lensLock: device.supportsPrimaryConstituentLock
        case .focusRect: device.supportsFocusRectOfInterest
        case .exposureRect: device.supportsExposureRectOfInterest
        case .subjectTracking: device.supportsContinuousAutoFocusTracking
        case .smudgeDetection: device.supportsLensSmudgeDetection
        case .lowLightNoiseReduction: device.supportsLowLightVideoNoiseReduction
        case .cinematicVideo: device.cinematicVideoDeviceType != nil
        case .dynamicAspectRatio: !device.supportedDynamicAspectRatios.isEmpty
        case .smartFraming: device.supportsSmartFraming
        }
    }

    /// ``name`` plus the device's range or list where it has one ("aperture f/1.8–4.0").
    func summary(for device: PRMCameraDevice) -> String {
        switch self {
        case .variableAperture:
            guard let range = device.apertureRange else { return name }
            return name + String(format: " f/%.1f–%.1f", range.lowerBound, range.upperBound)
        case .exposureSignals:
            return name + " " + device.supportedExposureSignals.map(\.rawValue).sorted().joined(separator: "/")
        case .cinematicVideo:
            var text = name
            if let fps = device.cinematicFrameRateRange { text += " ≤\(Int(fps.upperBound)) fps" }
            if let zoom = device.cinematicZoomRange {
                text += String(format: ", zoom %.1f–%.1f", zoom.lowerBound, zoom.upperBound)
            }
            if let aperture = device.simulatedApertureRange {
                text += String(format: ", depth f/%.1f–%.1f", aperture.lowerBound, aperture.upperBound)
            }
            return text
        case .dynamicAspectRatio:
            return name + " " + device.supportedDynamicAspectRatios.map(\.rawValue).joined(separator: "/")
        default:
            return name
        }
    }
}
