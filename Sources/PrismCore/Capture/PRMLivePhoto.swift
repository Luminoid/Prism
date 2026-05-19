import Foundation

/// A captured Live Photo: the still image plus the paired movie file URL.
///
/// The movie is written to `<tmp>/Prism/<uuid>.mov`. Consumers are responsible for moving
/// or deleting the file (typically by saving both pieces as a paired resource to
/// `PHPhotoLibrary` via `PHAssetCreationRequest`).
public struct PRMLivePhoto: @unchecked Sendable {
    /// The still image portion (data + AVCapturePhoto + metadata).
    public let photo: PRMPhoto

    /// On-disk URL of the paired movie. Caller owns the lifecycle.
    public let movieURL: URL

    public init(photo: PRMPhoto, movieURL: URL) {
        self.photo = photo
        self.movieURL = movieURL
    }
}
