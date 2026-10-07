//
//  PRMLog+Categories.swift
//  PrismCore
//
//  Prism's log categories and small logging helpers. The core in `PRMLog.swift` is shared
//  across Luminoid packages; everything Prism-specific lives here.
//

import AVFoundation
import Foundation

// MARK: - Categories

package extension PRMLog.Category {
    /// Session lifecycle, configuration, device switches, device controls.
    static let session = PRMLog.Category("Session")
    /// Photo, Live Photo and movie capture.
    static let capture = PRMLog.Category("Capture")
    /// Filter pipeline, renderers and buffer pools.
    static let filter = PRMLog.Category("Filter")
    /// Metal preview.
    static let preview = PRMLog.Category("Preview")
    /// Utilities and anything without a better home.
    static let general = PRMLog.Category("General")
}

// MARK: - Helpers

package extension PRMLog {
    /// Runs a best-effort call whose failure the caller tolerates (device configuration on
    /// slider ticks, cleanup during a swap) and writes a warning when it throws, instead of
    /// dropping the error with `try?`.
    ///
    /// - Parameters:
    ///   - operation: Static name of the call, e.g. `"setZoom"`; the warning reads "`operation` failed".
    ///   - throttled: For calls repeated many times a second: write the first failure only,
    ///     until the same operation succeeds again.
    /// - Returns: The call's result, or `nil` when it threw.
    @discardableResult
    static func bestEffort<T>(
        _ category: Category,
        _ operation: String,
        throttled: Bool = false,
        file: String = #fileID,
        line: Int = #line,
        _ body: () throws -> T
    ) -> T? {
        do {
            let result = try body()
            if throttled {
                resetOnce("bestEffort.\(operation)")
            }
            return result
        } catch {
            if throttled {
                once("bestEffort.\(operation)", .warning, category, "\(operation) failed", error: error, file: file, line: line)
            } else {
                warning(category, "\(operation) failed", error: error, file: file, line: line)
            }
            return nil
        }
    }

    /// A `once` key unique to one instance (`"<name>.<UUID>"`), for objects that can exist
    /// side by side and must not silence each other. Reset it from the owner's `deinit` so
    /// the remembered keys don't grow.
    static func instanceKey(_ name: String) -> String {
        "\(name).\(UUID().uuidString)"
    }

    /// A four-character code as text (`"BGRA"`, `"420f"`), or its number when it isn't printable.
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20 ..< 0x7F).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii)
        else { return String(code) }
        return text
    }
}

// MARK: - Log names

// Short, stable names for AVFoundation values in public log text.

extension AVCaptureDevice.Position {
    var prm_logName: String {
        switch self {
        case .back: "back"
        case .front: "front"
        case .unspecified: "unspecified"
        @unknown default: "position \(rawValue)"
        }
    }
}

extension AVCaptureDevice.DeviceType {
    /// `"BuiltInTripleCamera"` rather than `"AVCaptureDeviceTypeBuiltInTripleCamera"`.
    var prm_logName: String {
        rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: "")
    }
}

extension AVCaptureSession.Preset {
    /// `"Photo"` rather than `"AVCaptureSessionPresetPhoto"`.
    var prm_logName: String {
        rawValue.replacingOccurrences(of: "AVCaptureSessionPreset", with: "")
    }
}

extension AVCaptureSession.InterruptionReason {
    var prm_logName: String {
        if #available(iOS 26.0, *), self == .sensitiveContentMitigationActivated {
            return "sensitiveContentMitigationActivated"
        }
        return switch self {
        case .videoDeviceNotAvailableInBackground: "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient: "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure: "videoDeviceNotAvailableDueToSystemPressure"
        default: "reason \(rawValue)"
        }
    }
}

extension ProcessInfo.ThermalState {
    var prm_logName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "state \(rawValue)"
        }
    }
}

extension PRMSystemPressure {
    /// `"serious (systemTemperature, cameraTemperature)"`.
    var logDescription: String {
        let named: [(Factors, String)] = [
            (.systemTemperature, "systemTemperature"),
            (.peakPower, "peakPower"),
            (.depthModuleTemperature, "depthModuleTemperature"),
            (.cameraTemperature, "cameraTemperature"),
            (.batteryStress, "batteryStress"),
        ]
        let factorNames = named.filter { factors.contains($0.0) }.map(\.1)
        return factorNames.isEmpty ? "\(level)" : "\(level) (\(factorNames.joined(separator: ", ")))"
    }
}
