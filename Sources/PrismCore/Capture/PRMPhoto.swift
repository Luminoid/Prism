import AVFoundation
import Foundation

/// A captured photo, ready to save or post-process.
///
/// Returned by ``PRMPhotoCapture/capturePhoto(with:settings:applying:)``.
public struct PRMPhoto: @unchecked Sendable {
    /// Encoded image data (JPEG, HEIC, etc. — matches `PRMPhotoSettings.codec`).
    public let data: Data

    /// The raw `AVCapturePhoto` reference, retained for advanced consumers (depth, portrait
    /// effects matte, etc.).
    public let underlyingPhoto: AVCapturePhoto

    /// EXIF/TIFF metadata dictionaries extracted from the underlying photo's properties.
    public let metadata: [String: Any]

    /// When capture finished (server time).
    public let timestamp: Date

    public init(
        data: Data,
        underlyingPhoto: AVCapturePhoto,
        metadata: [String: Any],
        timestamp: Date = Date()
    ) {
        self.data = data
        self.underlyingPhoto = underlyingPhoto
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
