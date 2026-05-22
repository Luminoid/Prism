#if canImport(UIKit) && canImport(AVKit)
    import AVKit
    import UIKit

    // MARK: - PRMCaptureEventHelper

    /// Wraps `AVCaptureEventInteraction` (iOS 17.2+) for hardware capture controls — Camera
    /// Control button on iPhone 16+ and volume buttons.
    ///
    /// ```swift
    /// let helper = PRMCaptureEventHelper()
    /// helper.onPrimaryAction = { camera.capturePhoto() }
    /// previewView.addInteraction(helper.makeInteraction())
    /// ```
    @available(iOS 17.2, *)
    public final class PRMCaptureEventHelper {
        public var onPrimaryAction: (() -> Void)?
        public var onSecondaryAction: (() -> Void)?

        private var cachedInteraction: AVCaptureEventInteraction?

        public init() {}

        /// Returns the single `AVCaptureEventInteraction` owned by this helper, building
        /// it lazily on first access. Subsequent calls return the same instance — adding
        /// the *same* interaction to multiple views is supported by AVKit, but creating a
        /// fresh interaction per call and adding both to the same view would double-fire
        /// every Camera Control / volume-button event (each interaction has its own
        /// handler block). Memoizing here makes the helper safe to call from
        /// `viewWillAppear` / re-attachment paths without bookkeeping at the call site.
        public func makeInteraction() -> AVCaptureEventInteraction {
            if let cachedInteraction { return cachedInteraction }
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onPrimaryAction?() }
            } secondary: { [weak self] event in
                if event.phase == .ended { self?.onSecondaryAction?() }
            }
            cachedInteraction = interaction
            return interaction
        }
    }
#endif
