import AVFoundation

/// A Sendable snapshot of one `AVMetadataObject` delivered by the session's metadata output:
/// the iOS 27 focus-tracked subject, or the faces / bodies / pets that Cinematic Video
/// detects. Delivered on ``PRMCamera/detectedObjectsStream()``.
public struct PRMDetectedObject: Sendable, Equatable {
    /// What the metadata output detected.
    public enum Kind: Sendable, Hashable {
        /// iOS 27: the subject continuous autofocus tracking is following.
        case focusTracked
        case face
        case humanBody
        case humanFullBody
        case catHead
        case catBody
        case dogHead
        case dogBody
        case salientObject
        /// Any other metadata type; the raw AVFoundation identifier.
        case other(String)
    }

    public var kind: Kind

    /// Bounds in normalized device coordinates (`0...1`, origin top-left of the unrotated
    /// sensor image). Convert to view space the same way as a tap-to-focus point.
    public var bounds: CGRect

    /// iOS 26: a stable identifier for the object across frames. Pass it to
    /// ``PRMCinematicFocusRequest/trackObject(id:mode:)``. `nil` when unavailable.
    public var objectID: Int?

    /// iOS 26: identifies objects that belong together (a person's face and body). `nil`
    /// when unavailable.
    public var groupID: Int?

    /// iOS 26: the Cinematic Video focus mode applied to this object, if it is the focus
    /// target.
    public var cinematicFocusMode: PRMCinematicFocusMode?

    /// iOS 26: whether Cinematic Video has fixed focus on this object.
    public var isFixedFocus: Bool

    /// Presentation timestamp in seconds.
    public var timestampSeconds: Double

    public init(
        kind: Kind,
        bounds: CGRect,
        objectID: Int? = nil,
        groupID: Int? = nil,
        cinematicFocusMode: PRMCinematicFocusMode? = nil,
        isFixedFocus: Bool = false,
        timestampSeconds: Double = 0
    ) {
        self.kind = kind
        self.bounds = bounds
        self.objectID = objectID
        self.groupID = groupID
        self.cinematicFocusMode = cinematicFocusMode
        self.isFixedFocus = isFixedFocus
        self.timestampSeconds = timestampSeconds
    }

    /// Center of ``bounds``, handy for re-targeting focus at the object.
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// AVFoundation reports "no identifier" as `-1`.
    static func identifier(_ raw: Int) -> Int? {
        raw < 0 ? nil : raw
    }

    init(_ object: AVMetadataObject) {
        var objectID: Int?
        var groupID: Int?
        var focusMode: PRMCinematicFocusMode?
        var isFixedFocus = false
        if #available(iOS 26.0, *) {
            objectID = Self.identifier(object.objectID)
            groupID = Self.identifier(object.groupID)
            let mode = PRMCinematicFocusMode(object.cinematicVideoFocusMode)
            focusMode = mode == .none ? nil : mode
            isFixedFocus = object.isFixedFocus
        }
        self.init(
            kind: Kind(object.type),
            bounds: object.bounds,
            objectID: objectID,
            groupID: groupID,
            cinematicFocusMode: focusMode,
            isFixedFocus: isFixedFocus,
            timestampSeconds: CMTimeGetSeconds(object.time)
        )
    }
}

extension PRMDetectedObject.Kind {
    init(_ type: AVMetadataObject.ObjectType) {
        if #available(iOS 27.0, *), type == .focusTrackedObject {
            self = .focusTracked
            return
        }
        if #available(iOS 26.0, *) {
            if type == .catHead {
                self = .catHead
                return
            }
            if type == .dogHead {
                self = .dogHead
                return
            }
        }
        switch type {
        case .face: self = .face
        case .humanBody: self = .humanBody
        case .humanFullBody: self = .humanFullBody
        case .catBody: self = .catBody
        case .dogBody: self = .dogBody
        case .salientObject: self = .salientObject
        default: self = .other(type.rawValue)
        }
    }
}
