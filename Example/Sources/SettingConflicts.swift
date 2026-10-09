import Foundation

// MARK: - SettingChange

/// What one setting changed in others so it could take effect: the Example's rule for
/// settings that can't be on together is that the newest wins, turning the others off (or a
/// requirement on) and saying so in one toast and one log line.
///
/// Refusals (the camera can't do it, or a recording would have to stop) go through
/// ``ToastPresenter/refused(_:because:)`` instead.
struct SettingChange {
    // MARK: - Types

    struct Effect: Equatable {
        let name: String
        let turnedOn: Bool
        let reason: String
    }

    // MARK: - Properties

    /// The setting the user turned on (a control or mode name).
    let setting: String
    private(set) var effects: [Effect] = []

    var isEmpty: Bool {
        effects.isEmpty
    }

    // MARK: - Init

    init(_ setting: String) {
        self.setting = setting
    }

    // MARK: - Recording

    mutating func turnedOff(_ name: String, because reason: String) {
        effects.append(Effect(name: name, turnedOn: false, reason: reason))
    }

    mutating func turnedOn(_ name: String, because reason: String) {
        effects.append(Effect(name: name, turnedOn: true, reason: reason))
    }

    // MARK: - Text

    /// "Max Dimensions turned off manual exposure and locked white balance: manual photos are
    /// 12 MP." Several reasons are listed in order, separated by semicolons.
    var message: String {
        "\(summary): \(reasons.joined(separator: "; "))."
    }

    /// "Conflict: Max Dimensions turned off manual exposure (manual photos are 12 MP)".
    var logLine: String {
        "Conflict: \(summary) (\(reasons.joined(separator: "; ")))"
    }

    /// "Portrait matte turned on Depth and turned off Auto-deferred delivery".
    private var summary: String {
        let off = effects.filter { !$0.turnedOn }.map(\.name)
        let on = effects.filter(\.turnedOn).map(\.name)
        var clauses: [String] = []
        if !on.isEmpty {
            clauses.append("turned on \(ListFormatter.localizedString(byJoining: on))")
        }
        if !off.isEmpty {
            clauses.append("turned off \(ListFormatter.localizedString(byJoining: off))")
        }
        return "\(setting) \(clauses.joined(separator: " and "))"
    }

    private var reasons: [String] {
        effects.map(\.reason).reduce(into: []) { unique, reason in
            if !unique.contains(reason) { unique.append(reason) }
        }
    }
}
