#if canImport(UIKit) && canImport(AVKit)
    import AVKit
    import UIKit

    // MARK: - PRMCaptureControlHelper

    /// Wraps `AVCaptureEventInteraction` for handling hardware camera controls
    /// (Camera Control button on iPhone 16+, volume buttons).
    ///
    /// ```swift
    /// let helper = PRMCaptureControlHelper()
    /// helper.onPrimaryAction = { /* take photo */ }
    /// helper.onSecondaryAction = { /* toggle mode */ }
    /// let interaction = helper.makeInteraction()
    /// previewView.addInteraction(interaction)
    /// ```
    ///
    /// - Note: `AVCaptureEventInteraction` requires iOS 17.2+ and an active `AVCaptureSession`.
    @available(iOS 17.2, *)
    public final class PRMCaptureControlHelper {
        // MARK: - Callbacks

        /// Called when the primary capture action fires (Camera Control / volume down).
        public var onPrimaryAction: (() -> Void)?

        /// Called when the secondary capture action fires (volume up).
        public var onSecondaryAction: (() -> Void)?

        // MARK: - Initialization

        public init() {}

        // MARK: - Interaction

        /// Creates an `AVCaptureEventInteraction` wired to the callback properties.
        ///
        /// Add the returned interaction to your camera preview view:
        /// ```swift
        /// previewView.addInteraction(helper.makeInteraction())
        /// ```
        public func makeInteraction() -> AVCaptureEventInteraction {
            AVCaptureEventInteraction { [weak self] event in
                // Primary: fires on .ended phase
                if event.phase == .ended {
                    self?.onPrimaryAction?()
                }
            } secondary: { [weak self] event in
                // Secondary: fires on .ended phase
                if event.phase == .ended {
                    self?.onSecondaryAction?()
                }
            }
        }

        /// Whether the current device supports capture event interactions.
        ///
        /// Returns `true` on iOS 17.2+ (runtime availability is handled by the OS).
        public static var isSupported: Bool {
            true
        }
    }
#endif
