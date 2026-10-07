@preconcurrency import AVFoundation

// MARK: - Session health (iOS 26 / 27)

//
// Lens smudge detection and low-light video noise reduction. Both rebuild the capture
// pipeline, so both wait for the photo output to settle before returning. Status lands in
// ``PRMCameraState`` (`lensSmudgeStatus`, `isLowLightVideoNoiseReductionActive`,
// `systemPressure`, `interruptionReason`), refreshed by the device observers.

public extension PRMCamera {
    /// Turns lens smudge detection on or off (iOS 26). `nil` = off, `.invalid` = once per
    /// session start, `.zero` = continuously, otherwise the interval between runs. No-op
    /// where unsupported (see ``PRMCameraDevice/supportsLensSmudgeDetection``).
    func setLensSmudgeDetection(interval: CMTime?) async {
        await session.setLensSmudgeDetection(interval: interval)
        _ = await session.awaitPhotoOutputReady()
        await refreshState()
    }

    /// Sets the low-light video noise reduction policy (iOS 27) for recording and preview.
    func setLowLightVideoNoiseReduction(_ mode: PRMLowLightVideoNoiseReduction) async {
        await session.setLowLightVideoNoiseReduction(mode)
        _ = await session.awaitPhotoOutputReady()
        await refreshState()
    }
}
