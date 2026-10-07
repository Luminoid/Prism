#if canImport(UIKit) && canImport(AVKit)
    import AVKit
    import PrismCore
    import UIKit

    // MARK: - PRMCaptureSound

    /// A sound for an AirPods Camera Control capture (iOS 26). See
    /// ``PRMCaptureEventHelper/primarySound``.
    public enum PRMCaptureSound: Sendable, Equatable {
        /// The system camera shutter.
        case shutter
        /// The system "recording started" sound.
        case beginRecording
        /// The system "recording stopped" sound.
        case endRecording
        /// A sound file inside the app bundle.
        case custom(URL)

        /// The AVKit sound object, or `nil` when a custom file can't be loaded.
        @available(iOS 26.0, *)
        func makeEventSound() -> AVCaptureEventSound? {
            switch self {
            case .shutter: .cameraShutter
            case .beginRecording: .beginVideoRecording
            case .endRecording: .endVideoRecording
            case let .custom(url):
                // Played on every capture event, so one line until a sound loads again.
                PRMLog.bestEffort(.general, "AVCaptureEventSound(url:)", throttled: true) {
                    try AVCaptureEventSound(url: url)
                }
            }
        }
    }

    // MARK: - PRMCaptureEventHelper

    /// Wraps `AVCaptureEventInteraction` (iOS 17.2+) for hardware capture controls — Camera
    /// Control button on iPhone 16+, volume buttons, and (iOS 26) a click on an AirPods stem.
    ///
    /// ```swift
    /// let helper = PRMCaptureEventHelper()
    /// helper.onPrimaryAction = { [photoCapture] in
    ///     Task { _ = try await photoCapture.capturePhoto() }
    /// }
    /// previewView.addInteraction(helper.makeInteraction())
    /// ```
    ///
    /// **AirPods Camera Control (iOS 26).** The stem click arrives through the same
    /// interaction, so it fires ``onPrimaryAction`` with no extra code, and the system plays
    /// its capture sound through the AirPods. To play your own sound instead, set
    /// ``usesCustomCaptureSounds`` and ``primarySound`` / ``secondarySound``: the helper then
    /// plays that sound whenever the event asks for one (`AVCaptureEvent.shouldPlaySound`,
    /// true only for AirPods clicks with the default sound off). Leaving a sound `nil` while
    /// custom sounds are on means AirPods users hear nothing, which Apple calls out as a poor
    /// experience. AirPods Camera Control is not available in the European Union.
    public final class PRMCaptureEventHelper {
        public var onPrimaryAction: (() -> Void)?
        public var onSecondaryAction: (() -> Void)?

        /// iOS 26: sound played for an AirPods-triggered primary action when
        /// ``usesCustomCaptureSounds`` is on. Ignored on earlier systems.
        public var primarySound: PRMCaptureSound?

        /// iOS 26: sound played for an AirPods-triggered secondary action when
        /// ``usesCustomCaptureSounds`` is on. Ignored on earlier systems.
        public var secondarySound: PRMCaptureSound?

        private var cachedInteraction: AVCaptureEventInteraction?

        public init() {}

        /// iOS 26: turns off the system capture sound for every capture event interaction in
        /// the app (it's a global AVKit setting), so ``primarySound`` / ``secondarySound``
        /// play instead. Always `false` before iOS 26.
        public static var usesCustomCaptureSounds: Bool {
            get {
                guard #available(iOS 26.0, *) else { return false }
                return AVCaptureEventInteraction.defaultCaptureSoundDisabled
            }
            set {
                guard #available(iOS 26.0, *) else { return }
                AVCaptureEventInteraction.defaultCaptureSoundDisabled = newValue
            }
        }

        /// Returns the single `AVCaptureEventInteraction` owned by this helper, building
        /// it lazily on first access. Subsequent calls return the same instance: a fresh
        /// interaction per call, added to the same view, would double-fire every Camera
        /// Control / volume-button event (each interaction has its own handler block).
        /// Memoizing makes the helper safe to call from `viewWillAppear` / re-attachment
        /// paths without bookkeeping at the call site. Like any `UIInteraction` it belongs to
        /// one view at a time; adding it to another view moves it there.
        public func makeInteraction() -> AVCaptureEventInteraction {
            if let cachedInteraction { return cachedInteraction }
            let interaction = AVCaptureEventInteraction { [weak self] event in
                guard event.phase == .ended, let self else { return }
                playSoundIfRequested(for: event, sound: primarySound)
                onPrimaryAction?()
            } secondary: { [weak self] event in
                guard event.phase == .ended, let self else { return }
                playSoundIfRequested(for: event, sound: secondarySound)
                onSecondaryAction?()
            }
            cachedInteraction = interaction
            return interaction
        }

        private func playSoundIfRequested(for event: AVCaptureEvent, sound: PRMCaptureSound?) {
            guard #available(iOS 26.0, *), event.shouldPlaySound,
                  let eventSound = sound?.makeEventSound()
            else { return }
            event.play(eventSound)
        }
    }
#endif
