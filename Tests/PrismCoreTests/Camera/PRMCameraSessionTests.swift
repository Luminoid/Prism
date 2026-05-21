import AVFoundation
import Testing
@testable import PrismCore

struct PRMCameraSessionTests {
    @Test
    @PRMCameraActor
    func `Initialization yields a fresh session`() {
        let session = PRMCameraSession()
        #expect(session.configuration == nil)
        #expect(session.videoDevice == nil)
        #expect(!session.isRunning)
    }

    @Test
    func `makeDefaultMainActor is callable from any context`() {
        let session = PRMCameraSession.makeDefaultMainActor()
        // Just verify the factory works; we can't query actor-isolated state here.
        _ = session.session
    }

    @Test
    @PRMCameraActor
    func `switchDevice throws when there's no current input`() {
        // Pre-configure: no input attached yet, so `swapInput` exits via the
        // `No current input to swap` branch before any device discovery happens. This
        // is the simulator-safe path for verifying the API exists and surfaces errors.
        let session = PRMCameraSession()
        do {
            _ = try session.switchDevice(type: .builtInWideAngleCamera)
            Issue.record("switchDevice should have thrown without a current input")
        } catch let error as PRMSessionError {
            // Either "no input to swap" (no device attached) or "no device of type"
            // (input attached but discovery failed) is acceptable; both prove the API
            // is wired and short-circuits before AVFoundation does anything destructive.
            switch error {
            case .cannotAttachToSession, .noDeviceOfType:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func `API surface compiles against documented key paths`() {
        let switchDeviceKP: KeyPath<PRMCameraSession, (AVCaptureDevice.DeviceType, AVCaptureDevice.Position?) throws -> AVCaptureDevice>? = nil
        _ = switchDeviceKP
        // Compile-time check that the method signature didn't drift.
        _ = PRMCameraSession.switchDevice(type:position:)
    }
}
