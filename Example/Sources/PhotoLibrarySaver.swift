import Foundation
import Photos
import PrismCore

// MARK: - PhotoLibrarySaver

/// Saves the demos' captures to the photo library with add-only access.
///
/// Everything here is nonisolated on purpose. `PHPhotoLibrary.performChanges` runs its
/// closure on Photos' own queue, and a closure formed inside a `@MainActor` method inherits
/// main-actor isolation: Swift 6 then aborts with `_dispatch_assert_queue_fail` when Photos
/// calls it. The same applies to any framework callback run on its own queue
/// (`PHPhotoLibrary.performChanges`, `BGTaskScheduler.register`).
enum PhotoLibrarySaver {
    // MARK: - Types

    enum Resource: Sendable {
        case photo(Data)
        /// A Live Photo still and its paired movie. The movie file moves into the library.
        case livePhoto(photo: Data, movieURL: URL)
        /// A recording. The file moves into the library.
        case video(URL)
    }

    enum Failure: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Photo library access denied"
        }
    }

    // MARK: - Saving

    /// Asks for add-only access when it hasn't been decided, then saves. When the save fails,
    /// a movie file is deleted rather than left in the temporary directory.
    static func save(_ resource: Resource) async throws {
        do {
            guard await hasAddAccess() else { throw Failure.accessDenied }
            try await PHPhotoLibrary.shared().performChanges {
                addAsset(for: resource)
            }
        } catch {
            if let movieURL = movieURL(of: resource) {
                PRMTempFile.remove(movieURL)
            }
            throw error
        }
    }

    /// "JPEG" or "HEIC" from the file's first bytes (the JPEG SOI marker, the ISO media
    /// `ftyp` box), so a status line can confirm which encoder actually ran; "?" otherwise.
    static func containerLabel(for data: Data) -> String {
        guard data.count >= 12 else { return "?" }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "JPEG" }
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "HEIC" }
        return "?"
    }

    // MARK: - Helpers

    private static func hasAddAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return status == .authorized || status == .limited
    }

    private static func addAsset(for resource: Resource) {
        let request = PHAssetCreationRequest.forAsset()
        let moveFile = PHAssetResourceCreationOptions()
        moveFile.shouldMoveFile = true
        switch resource {
        case let .photo(data):
            request.addResource(with: .photo, data: data, options: nil)
        case let .livePhoto(photo, movieURL):
            request.addResource(with: .photo, data: photo, options: nil)
            request.addResource(with: .pairedVideo, fileURL: movieURL, options: moveFile)
        case let .video(url):
            request.addResource(with: .video, fileURL: url, options: moveFile)
        }
    }

    private static func movieURL(of resource: Resource) -> URL? {
        switch resource {
        case .photo: nil
        case let .livePhoto(_, movieURL): movieURL
        case let .video(url): url
        }
    }
}
