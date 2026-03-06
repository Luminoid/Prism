import AVFoundation
import Testing
@testable import PrismCore

@Suite("PRMPermissionHelper")
struct PRMPermissionHelperTests {
    // MARK: - PermissionStatus Enum

    @Test("PermissionStatus has all expected cases")
    func permissionStatusCases() {
        let statuses: [PRMPermissionHelper.PermissionStatus] = [
            .authorized, .denied, .restricted, .notDetermined,
        ]
        #expect(statuses.count == 4)
    }

    @Test("PermissionStatus is Sendable")
    func permissionStatusSendable() {
        let status: PRMPermissionHelper.PermissionStatus = .authorized
        let sendable: any Sendable = status
        #expect(sendable is PRMPermissionHelper.PermissionStatus)
    }

    // MARK: - Camera Status

    @Test("Camera status returns a valid status")
    func cameraStatusReturns() {
        let status = PRMPermissionHelper.cameraStatus()
        let validStatuses: [PRMPermissionHelper.PermissionStatus] = [
            .authorized, .denied, .restricted, .notDetermined,
        ]
        #expect(validStatuses.contains(where: { isEqual($0, status) }))
    }

    // MARK: - Microphone Status

    @Test("Microphone status returns a valid status")
    func microphoneStatusReturns() {
        let status = PRMPermissionHelper.microphoneStatus()
        let validStatuses: [PRMPermissionHelper.PermissionStatus] = [
            .authorized, .denied, .restricted, .notDetermined,
        ]
        #expect(validStatuses.contains(where: { isEqual($0, status) }))
    }

    // MARK: - Settings URL

    #if canImport(UIKit)
        @Test("Settings URL is non-nil on iOS")
        func settingsURLNonNil() {
            let url = PRMPermissionHelper.settingsURL()
            #expect(url != nil)
        }

        @Test("Settings URL contains expected prefix")
        func settingsURLPrefix() {
            let url = PRMPermissionHelper.settingsURL()
            #expect(url?.absoluteString.hasPrefix("App-prefs:") == true || url?.absoluteString.hasPrefix("app-settings:") == true)
        }
    #endif

    // MARK: - API Signature Verification

    @Test("requestCameraAccess is async and returns Bool")
    func requestCameraAccessSignature() {
        // Verify the function signature exists — don't actually call it in tests
        // as it triggers a system permission dialog
        let _: () async -> Bool = PRMPermissionHelper.requestCameraAccess
    }

    @Test("requestMicrophoneAccess is async and returns Bool")
    func requestMicrophoneAccessSignature() {
        let _: () async -> Bool = PRMPermissionHelper.requestMicrophoneAccess
    }

    // MARK: - Helpers

    private func isEqual(
        _ lhs: PRMPermissionHelper.PermissionStatus,
        _ rhs: PRMPermissionHelper.PermissionStatus,
    ) -> Bool {
        switch (lhs, rhs) {
        case (.authorized, .authorized),
             (.denied, .denied),
             (.restricted, .restricted),
             (.notDetermined, .notDetermined):
            true
        default:
            false
        }
    }
}
