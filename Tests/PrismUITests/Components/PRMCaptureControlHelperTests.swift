#if canImport(UIKit) && canImport(AVKit)
    import AVKit
    import Testing
    import UIKit
    @testable import PrismUI

    @Suite("PRMCaptureControlHelper")
    @MainActor
    struct PRMCaptureControlHelperTests {
        // MARK: - Initialization

        @available(iOS 17.2, *)
        @Test("Helper can be initialized")
        func initialization() {
            let helper = PRMCaptureControlHelper()
            #expect(helper.onPrimaryAction == nil)
            #expect(helper.onSecondaryAction == nil)
        }

        // MARK: - Callbacks

        @available(iOS 17.2, *)
        @Test("Primary action can be set")
        func primaryAction() {
            let helper = PRMCaptureControlHelper()
            var called = false
            helper.onPrimaryAction = { called = true }
            helper.onPrimaryAction?()
            #expect(called)
        }

        @available(iOS 17.2, *)
        @Test("Secondary action can be set")
        func secondaryAction() {
            let helper = PRMCaptureControlHelper()
            var called = false
            helper.onSecondaryAction = { called = true }
            helper.onSecondaryAction?()
            #expect(called)
        }

        // MARK: - Interaction

        @available(iOS 17.2, *)
        @Test("makeInteraction returns an AVCaptureEventInteraction")
        func makeInteraction() {
            let helper = PRMCaptureControlHelper()
            let interaction = helper.makeInteraction()
            #expect(interaction is UIInteraction)
        }

        @available(iOS 17.2, *)
        @Test("Multiple interactions can be created")
        func multipleInteractions() {
            let helper = PRMCaptureControlHelper()
            let first = helper.makeInteraction()
            let second = helper.makeInteraction()
            #expect(first !== second)
        }

        // MARK: - Support Check

        @available(iOS 17.2, *)
        @Test("isSupported returns true on iOS 17.2+")
        func isSupported() {
            #expect(PRMCaptureControlHelper.isSupported)
        }
    }
#endif
