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

public extension PRMCameraActor {
    /// Runs `body` and returns its result. The body is **not** isolated to the actor: it's a
    /// `@Sendable` closure, so every `await` on actor state inside it is its own hop and other
    /// work can run between them. Use it for independent reads. Anything that must check and
    /// change session state atomically belongs in a synchronous `@PRMCameraActor` method on
    /// ``PRMCameraSession`` (or a `Task { @PRMCameraActor in … }.value`).
    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await body()
    }
}
