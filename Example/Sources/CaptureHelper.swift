import AVFoundation
import CoreImage
import PrismCore
import UIKit

// MARK: - CaptureHelper

/// Shared photo capture + save logic used by all camera screens.
/// Captures a filtered photo via `PRMPhotoCaptureProcessor` and saves to the photo library.
@MainActor
enum CaptureHelper {
    /// Retains the active processor to prevent premature deallocation.
    /// AVFoundation retains the delegate during capture, but this provides
    /// belt-and-suspenders safety against edge cases.
    private(set) static var activeProcessor: PRMPhotoCaptureProcessor?

    /// Captures a photo with optional filter and saves to the photo library.
    ///
    /// - Parameters:
    ///   - sessionManager: The camera session manager (must have `photoOutput`).
    ///   - filter: An optional filter to apply to the captured photo.
    ///   - flashMode: Flash mode for capture (default `.off`).
    ///   - willCapture: Called when the shutter fires (for animation).
    ///   - completion: Called with a success/failure message on the main queue.
    static func captureAndSave(
        sessionManager: PRMCameraSessionManager,
        filter: (any PRMCameraFilter)?,
        flashMode: AVCaptureDevice.FlashMode = .off,
        willCapture: (() -> Void)? = nil,
        completion: @escaping @MainActor (String) -> Void,
    ) {
        guard let photoOutput = sessionManager.photoOutput else {
            completion("No photo output available")
            return
        }

        let settings = PRMPhotoSettingsBuilder()
            .flashMode(flashMode)
            .qualityPrioritization(.balanced)
            .build()

        let captureFilter = filter

        let processor = PRMPhotoCaptureProcessor(settings: settings) { photo -> Data? in
            guard let data = photo.fileDataRepresentation() else { return nil }

            if let captureFilter {
                if let ciImage = CIImage(data: data),
                   let filtered = captureFilter.render(image: ciImage) {
                    return PRMImageHelper.jpegData(from: filtered)
                }
            }
            return data
        }

        processor.willCapturePhotoHandler = willCapture

        processor.completionHandler = { completedProcessor in
            let data = completedProcessor.capturedPhotoData
            Task { @MainActor in
                activeProcessor = nil
                guard let data, let image = UIImage(data: data) else {
                    completion("Capture failed")
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                completion("Saved to Photos")
            }
        }

        activeProcessor = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    /// Shows a brief toast message in the given view.
    static func showToast(_ message: String, in view: UIView) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
            label.heightAnchor.constraint(equalToConstant: 32),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        UIView.animate(withDuration: 0.3, delay: 1.5) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}
