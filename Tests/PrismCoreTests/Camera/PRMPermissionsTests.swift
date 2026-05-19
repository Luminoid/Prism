import Testing
@testable import PrismCore

struct PRMPermissionsTests {
    @Test
    func `Camera status returns a known value`() {
        let status = PRMPermissions.cameraStatus()
        #expect([.authorized, .denied, .restricted, .notDetermined].contains(status))
    }

    @Test
    func `Microphone status returns a known value`() {
        let status = PRMPermissions.microphoneStatus()
        #expect([.authorized, .denied, .restricted, .notDetermined].contains(status))
    }

    @Test
    func `Settings URL exists on UIKit platforms`() {
        #expect(PRMPermissions.settingsURL() != nil)
    }
}
