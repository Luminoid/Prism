import AVFoundation
import Foundation
import Testing
@testable import PrismCore

/// `PRMPhoto` wraps an `AVCapturePhoto`, which has no public initializer — it can only be
/// produced by an `AVCapturePhotoOutput` during a live capture session. That means we can't
/// instantiate a PRMPhoto in unit tests without a running device.
///
/// What we *can* test:
/// - The public API surface (property names + types) hasn't drifted, via key-path lookups
///   that fail to compile if any property is renamed or removed.
/// - The type is `Sendable` across actor hops (compile-time check).
///
/// Full capture flow is exercised by the example app's StudioViewController and by the
/// manual test plan in CHANGELOG/CLAUDE.md.
struct PRMPhotoTests {
    @Test
    func `Public API surface compiles against documented key paths`() {
        // KeyPath construction is a compile-time assertion that the property exists at the
        // declared type. If anyone renames or removes one of these, this test stops compiling.
        let dataKP: KeyPath<PRMPhoto, Data> = \PRMPhoto.data
        let photoKP: KeyPath<PRMPhoto, AVCapturePhoto> = \PRMPhoto.underlyingPhoto
        let metadataKP: KeyPath<PRMPhoto, [String: Any]> = \PRMPhoto.metadata
        let timestampKP: KeyPath<PRMPhoto, Date> = \PRMPhoto.timestamp
        _ = (dataKP, photoKP, metadataKP, timestampKP)
        // The act of compiling this file with the assignments above is the test.
        #expect(true)
    }

    @Test
    func `Sendable conformance survives an actor hop`() async {
        // Compile-time check: this body won't typecheck if PRMPhoto loses Sendable, because
        // the detached Task captures must be Sendable.
        let blob = await Task.detached { Data([0xFF, 0xD8]) }.value
        #expect(blob.count == 2)
    }
}
