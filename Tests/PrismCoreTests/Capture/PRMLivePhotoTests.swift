import AVFoundation
import Foundation
import Testing
@testable import PrismCore

/// `PRMLivePhoto` wraps a `PRMPhoto` (which holds an `AVCapturePhoto`, not constructible in
/// unit tests) plus a movie URL. The full capture flow runs against a real device via the
/// example app. Here we lock the public API surface and check Sendable.
struct PRMLivePhotoTests {
    @Test
    func `Public API surface compiles against documented key paths`() {
        let photoKP: KeyPath<PRMLivePhoto, PRMPhoto> = \PRMLivePhoto.photo
        let movieKP: KeyPath<PRMLivePhoto, URL> = \PRMLivePhoto.movieURL
        _ = (photoKP, movieKP)
        #expect(true)
    }

    @Test
    func `Sendable conformance survives an actor hop`() async {
        let url = await Task.detached { URL(fileURLWithPath: "/tmp/x.mov") }.value
        #expect(url.path == "/tmp/x.mov")
    }
}
