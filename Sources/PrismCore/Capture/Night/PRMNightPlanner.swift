import Foundation

/// The camera's state a Night plan starts from.
struct PRMNightPlanInput: Sendable, Equatable {
    /// Auto exposure's current shutter (seconds) and ISO.
    var exposureDuration: Double
    var iso: Float
    /// `exposureTargetOffset` in EV: negative when auto exposure can't reach its target.
    var targetOffset: Float
    var minISO: Float
    var maxISO: Float
    var minExposureDuration: Double
    var maxExposureDuration: Double
    /// The shortest frame duration the format runs at (1/30 s at 30 fps); `0` for no limit.
    /// A shutter shorter than this still takes a whole frame.
    var minFrameDuration: Double = 0
    /// 35mm-equivalent focal length of the active lens.
    var focalLength35mm: Double
    var isStable: Bool
}

/// Picks a Night capture's exposure and length. Pure, so its choices are table-tested.
///
/// - **Exposure per frame:** auto exposure's *target* (`shutter × ISO × 2^-offset`), not what
///   it reached: in the dark auto exposure tops out at its frame-rate limit and falls short,
///   and reaching the target in the sensor is far cleaner than digital gain later. Each frame
///   sits 0.3 EV under it to keep highlights; the merge's noise reduction pays for the gain.
/// - **Shutter:** at most `3 / f35` handheld (1/8 s on a 24 mm lens, the limit sensor-shift
///   stabilization holds sharp), 1/2 s when stable, never past the format's maximum. ISO fills
///   in the rest within the format's range.
/// - **Length:** automatic picks 1, 2 or 3 s handheld (3, 6 or 10 s stable) from how much light
///   the target exposure needs; frames are the length over the frame interval (the shutter, or
///   the format's frame duration when a bright scene's shutter is shorter), 3 to 64.
enum PRMNightPlanner {
    static let highlightHeadroomEV: Double = 0.3
    static let maxFrames = 64
    static let minFrames = 3

    static func plan(_ input: PRMNightPlanInput, duration request: PRMNightModeOptions.Duration) -> PRMNightPlan {
        let minISO = Double(max(input.minISO, 1))
        let maxISO = Double(max(input.maxISO, input.minISO, 1))
        let minShutter = max(input.minExposureDuration, 1e-6)
        let maxShutter = max(input.maxExposureDuration, minShutter)

        // Exposure as shutter × ISO. Positive offsets (brighter than the target) keep what
        // auto exposure has.
        let offset = input.targetOffset.isFinite ? Double(min(max(input.targetOffset, -4), 0)) : 0
        let current = max(input.exposureDuration, minShutter) * Double(max(input.iso, input.minISO, 1))
        let target = current * pow(2, -offset)
        let perFrame = target * pow(2, -highlightHeadroomEV)

        let handheldCap = min(1.0 / 8.0, 3.0 / max(input.focalLength35mm, 1))
        let cap = min(input.isStable ? 0.5 : handheldCap, maxShutter)
        // Bright scenes reach the exposure at minimum ISO with a shorter shutter.
        let shutter = min(max(perFrame / minISO, minShutter), max(cap, minShutter))
        let iso = min(max(perFrame / shutter, minISO), maxISO)

        let seconds: Double = switch request {
        case let .seconds(value): min(max(value, 0.5), 30)
        case .automatic: automaticDuration(targetExposure: target, isStable: input.isStable)
        }
        // A 1/40 s shutter on a 30 fps format still delivers 30 frames a second, not 40.
        let interval = max(shutter, input.minFrameDuration)
        let frames = min(max(Int((seconds / interval).rounded()), minFrames), maxFrames)
        return PRMNightPlan(duration: seconds, frameDuration: shutter, iso: Float(iso), frameCount: frames)
    }

    /// Exposure the scene needs (shutter × ISO): about 400 is a dim room at night (ISO 3200 at
    /// 1/8 s), 100 a lit street.
    static func automaticDuration(targetExposure: Double, isStable: Bool) -> Double {
        let handheld: Double = if targetExposure >= 400 {
            3
        } else if targetExposure >= 100 {
            2
        } else {
            1
        }
        guard isStable else { return handheld }
        return switch handheld {
        case 3: 10
        case 2: 6
        default: 3
        }
    }
}
