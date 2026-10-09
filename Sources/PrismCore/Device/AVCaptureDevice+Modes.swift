import AVFoundation

// Names and per-device support for the exposure, white balance and focus modes, so errors
// and logs say "auto (one-shot)" instead of a raw value, and UIs can offer only the modes a
// camera runs (iPhone cameras have no one-shot auto white balance).

public extension AVCaptureDevice.ExposureMode {
    /// Every mode, in control order.
    static let prm_allCases: [AVCaptureDevice.ExposureMode] = [.locked, .autoExpose, .continuousAutoExposure, .custom]

    /// A short name for logs and messages: "locked", "auto (one-shot)", "continuous auto",
    /// "custom".
    var prm_name: String {
        switch self {
        case .locked: "locked"
        case .autoExpose: "auto (one-shot)"
        case .continuousAutoExposure: "continuous auto"
        case .custom: "custom"
        @unknown default: "mode \(rawValue)"
        }
    }
}

public extension AVCaptureDevice.WhiteBalanceMode {
    /// Every mode, in control order.
    static let prm_allCases: [AVCaptureDevice.WhiteBalanceMode] = [.locked, .autoWhiteBalance, .continuousAutoWhiteBalance]

    /// A short name for logs and messages: "locked", "auto (one-shot)", "continuous auto".
    var prm_name: String {
        switch self {
        case .locked: "locked"
        case .autoWhiteBalance: "auto (one-shot)"
        case .continuousAutoWhiteBalance: "continuous auto"
        @unknown default: "mode \(rawValue)"
        }
    }
}

public extension AVCaptureDevice.FocusMode {
    /// Every mode, in control order.
    static let prm_allCases: [AVCaptureDevice.FocusMode] = [.locked, .autoFocus, .continuousAutoFocus]

    /// A short name for logs and messages: "locked", "auto (one-shot)", "continuous auto".
    var prm_name: String {
        switch self {
        case .locked: "locked"
        case .autoFocus: "auto (one-shot)"
        case .continuousAutoFocus: "continuous auto"
        @unknown default: "mode \(rawValue)"
        }
    }
}

public extension AVCaptureDevice {
    /// The exposure modes this camera supports, in control order.
    var prm_supportedExposureModes: [ExposureMode] {
        ExposureMode.prm_allCases.filter(isExposureModeSupported)
    }

    /// The white balance modes this camera supports, in control order.
    var prm_supportedWhiteBalanceModes: [WhiteBalanceMode] {
        WhiteBalanceMode.prm_allCases.filter(isWhiteBalanceModeSupported)
    }

    /// The focus modes this camera supports, in control order.
    var prm_supportedFocusModes: [FocusMode] {
        FocusMode.prm_allCases.filter(isFocusModeSupported)
    }

    /// "Back Camera supports locked and continuous auto": the tail of an unsupported-mode
    /// error, so the message says what to pick instead.
    internal func prm_supportedModesText(_ names: [String]) -> String {
        "\(localizedName) supports \(Self.prm_listText(names))"
    }

    /// "a", "a and b", "a, b and c"; "no modes" when empty.
    internal static func prm_listText(_ names: [String]) -> String {
        switch names.count {
        case 0: "no modes"
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
