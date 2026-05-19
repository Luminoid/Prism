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

        public init() {}

        public func makeInteraction() -> AVCaptureEventInteraction {
            AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onPrimaryAction?() }
            } secondary: { [weak self] event in
                if event.phase == .ended { self?.onSecondaryAction?() }
            }
        }
    }
#endif
