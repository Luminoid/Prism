import AVFoundation

// MARK: - PRMAspectRatio

/// Output aspect ratio for iOS 26 dynamic aspect ratio (the square-sensor front camera on
/// iPhone 17 can frame portrait or landscape without the phone being rotated). Mirrors
/// `AVCaptureDevice.AspectRatio` as a Sendable value type.
public enum PRMAspectRatio: String, Sendable, CaseIterable, Hashable {
    case ratio1x1 = "1:1"
    case ratio16x9 = "16:9"
    case ratio9x16 = "9:16"
    case ratio4x3 = "4:3"
    case ratio3x4 = "3:4"

    /// Width divided by height.
    public var widthOverHeight: Double {
        switch self {
        case .ratio1x1: 1
        case .ratio16x9: 16.0 / 9.0
        case .ratio9x16: 9.0 / 16.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio3x4: 3.0 / 4.0
        }
    }

    /// Whether the frame is taller than it is wide.
    public var isPortrait: Bool {
        widthOverHeight < 1
    }
}

@available(iOS 26.0, *)
extension PRMAspectRatio {
    init?(_ ratio: AVCaptureDevice.AspectRatio) {
        switch ratio {
        case .ratio1x1: self = .ratio1x1
        case .ratio16x9: self = .ratio16x9
        case .ratio9x16: self = .ratio9x16
        case .ratio4x3: self = .ratio4x3
        case .ratio3x4: self = .ratio3x4
        default: return nil
        }
    }

    var avAspectRatio: AVCaptureDevice.AspectRatio {
        switch self {
        case .ratio1x1: .ratio1x1
        case .ratio16x9: .ratio16x9
        case .ratio9x16: .ratio9x16
        case .ratio4x3: .ratio4x3
        case .ratio3x4: .ratio3x4
        }
    }
}

// MARK: - PRMFraming

/// A framing recommended by the iOS 26 Smart Framing monitor: an aspect ratio plus a raw
/// `videoZoomFactor`. Apply it with ``PRMCamera/applyFraming(_:)``.
public struct PRMFraming: Sendable, Hashable {
    public var aspectRatio: PRMAspectRatio
    public var zoomFactor: Float

    public init(aspectRatio: PRMAspectRatio, zoomFactor: Float) {
        self.aspectRatio = aspectRatio
        self.zoomFactor = zoomFactor
    }

    @available(iOS 26.0, *)
    init?(_ framing: AVCaptureFraming) {
        guard let ratio = PRMAspectRatio(framing.aspectRatio) else { return nil }
        self.init(aspectRatio: ratio, zoomFactor: framing.zoomFactor)
    }
}

// MARK: - PRMVideoDimensions

/// Equatable stand-in for `CMVideoDimensions` so it can live in synthesized-`Equatable`
/// snapshots like ``PRMCameraState``.
public struct PRMVideoDimensions: Sendable, Hashable {
    public var width: Int32
    public var height: Int32

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    public init(_ dimensions: CMVideoDimensions) {
        self.init(width: dimensions.width, height: dimensions.height)
    }

    /// `true` when either side is zero (AVFoundation's "not applicable" value).
    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }
}
