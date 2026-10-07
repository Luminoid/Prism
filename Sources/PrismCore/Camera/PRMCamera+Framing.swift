@preconcurrency import AVFoundation

// MARK: - Dynamic aspect ratio and Smart Framing (iOS 26)

//
// The iPhone 17 front camera's square sensor can output portrait or landscape frames
// without the phone rotating, and its Smart Framing monitor suggests an aspect ratio and
// zoom for the people in frame. Prism applies nothing automatically: recommendations
// arrive on a stream and the app decides when to call `applyFraming(_:)`.

public extension PRMCamera {
    /// Changes the output aspect ratio (iOS 26). Returns once frames at the new ratio are
    /// flowing; the preview and filter pipeline adapt to the new buffer size on their own.
    /// Kept across camera switches and format changes where supported.
    ///
    /// - Throws: ``PRMSessionError/unsupportedConfiguration(_:)`` while recording, before
    ///   iOS 26, or when ``PRMCameraDevice/supportedDynamicAspectRatios`` lacks `ratio`.
    func setDynamicAspectRatio(_ ratio: PRMAspectRatio) async throws {
        do {
            try await session.setDynamicAspectRatio(ratio)
        } catch {
            await refreshState()
            throw error
        }
        await refreshState()
    }

    /// Framings the current camera's Smart Framing monitor can recommend (iOS 26). Empty
    /// for cameras without one.
    func supportedFramings() async -> [PRMFraming] {
        await session.supportedFramings()
    }

    /// Chooses which framings Smart Framing may recommend and starts monitoring while the
    /// session runs (iOS 26); `nil` stops it. Pick from ``supportedFramings()``.
    func setSmartFraming(enabledFramings: [PRMFraming]?) async {
        await session.setSmartFraming(enabledFramings: enabledFramings)
    }

    /// Smart Framing recommendations (iOS 26): the current one on subscribe, then a new value
    /// whenever the monitor changes its mind; `nil` when it has none. Coalesced to the
    /// latest value.
    func framingRecommendationStream() -> AsyncStream<PRMFraming?> {
        let current = session.latestFramingRecommendation.withLock { $0 }
        return session.framingRecommendations.makeStream(initial: .some(current))
    }

    /// Applies a framing: the aspect ratio first, then the zoom factor.
    func applyFraming(_ framing: PRMFraming) async throws {
        try await setDynamicAspectRatio(framing.aspectRatio)
        await setZoom(CGFloat(framing.zoomFactor))
    }
}
