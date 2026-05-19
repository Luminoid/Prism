/// Global actor that serializes all `AVCaptureSession` mutations.
///
/// Apple's AVFoundation operates against an internal serial dispatch queue and is not
/// thread-safe. Wrapping the session work in a global actor (rather than a hand-rolled
/// `DispatchQueue`) gives:
///
/// - Static (compile-time) guarantees that mutations are serialized.
/// - Native `await` ergonomics — no manual `sessionQueue.async {}` dance.
/// - Interop with Swift 6 strict concurrency.
///
/// Use ``PRMCamera`` (MainActor facade) from UI code. Drop down to this actor only when
/// you need to do work directly against the AVCaptureSession.
@globalActor
public actor PRMCameraActor {
    public static let shared = PRMCameraActor()
}
