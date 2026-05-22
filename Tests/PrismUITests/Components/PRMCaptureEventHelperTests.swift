#if canImport(UIKit) && canImport(AVKit)
    import AVKit
    import Testing
    @testable import PrismUI

    /// Tests for `PRMCaptureEventHelper`.
    ///
    /// `AVCaptureEventInteraction` is iOS 17.2+; the helper is annotated `@available(iOS 17.2, *)`,
    /// but Prism's deployment target is iOS 18, so it's always reachable here. Swift Testing's
    /// `@Test` macro forbids `@available` on test methods, so we test the helper directly
    /// without further availability gating.
    @MainActor
    struct PRMCaptureEventHelperTests {
        @Test
        func `Default-init produces a helper with no handlers assigned`() {
            let helper = PRMCaptureEventHelper()
            #expect(helper.onPrimaryAction == nil)
            #expect(helper.onSecondaryAction == nil)
        }

        @Test
        func `Handlers are storable and replaceable`() {
            let helper = PRMCaptureEventHelper()
            var primaryFired = false
            var secondaryFired = false
            helper.onPrimaryAction = { primaryFired = true }
            helper.onSecondaryAction = { secondaryFired = true }
            #expect(helper.onPrimaryAction != nil)
            #expect(helper.onSecondaryAction != nil)

            // Invoke them directly — proves the closure was stored, not silently dropped.
            helper.onPrimaryAction?()
            helper.onSecondaryAction?()
            #expect(primaryFired)
            #expect(secondaryFired)

            // Replacing clears the previous closure.
            helper.onPrimaryAction = nil
            #expect(helper.onPrimaryAction == nil)
        }

        @Test
        func `makeInteraction returns an AVCaptureEventInteraction`() {
            let helper = PRMCaptureEventHelper()
            let interaction = helper.makeInteraction()
            // Mere construction is the assertion — AVCaptureEventInteraction has no inspectable
            // public state, and creating one requires the closures (which the helper supplies).
            _ = interaction
        }

        @Test
        func `makeInteraction is memoized — repeated calls return the same instance`() {
            // The helper memoizes its `AVCaptureEventInteraction` so callers can invoke
            // `makeInteraction()` multiple times (e.g. from re-attachment paths like
            // `viewWillAppear`) without accidentally creating duplicate interactions that
            // would double-fire every Camera Control / volume-button event when both
            // ended up attached to the same view.
            let helper = PRMCaptureEventHelper()
            let a = helper.makeInteraction()
            let b = helper.makeInteraction()
            #expect(a === b)
        }
    }
#endif
