import AVFoundation

public extension AVCaptureDevice {
    /// Latest lens smudge detection result (iOS 26). `.disabled` before that.
    var prm_lensSmudgeStatus: PRMLensSmudgeStatus {
        guard #available(iOS 26.0, *) else { return .disabled }
        return PRMLensSmudgeStatus(cameraLensSmudgeDetectionStatus)
    }
}
