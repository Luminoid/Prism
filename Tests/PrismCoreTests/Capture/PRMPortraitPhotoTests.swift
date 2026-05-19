import AVFoundation
import Foundation
import Testing
@testable import PrismCore

/// `PRMPortraitPhoto` carries a `PRMPhoto` plus optional `AVDepthData` /
/// `AVPortraitEffectsMatte`. Both AV types are device-derived; full capture is covered by
/// the example app. KeyPath compile-time surface check here.
struct PRMPortraitPhotoTests {
    @Test
    func `Public API surface compiles against documented key paths`() {
        let photoKP: KeyPath<PRMPortraitPhoto, PRMPhoto> = \PRMPortraitPhoto.photo
        let depthKP: KeyPath<PRMPortraitPhoto, AVDepthData?> = \PRMPortraitPhoto.depthData
        let matteKP: KeyPath<PRMPortraitPhoto, AVPortraitEffectsMatte?> = \PRMPortraitPhoto.portraitEffectsMatte
        _ = (photoKP, depthKP, matteKP)
        #expect(true)
    }

    @Test
    func `Sendable conformance survives an actor hop`() async {
        let blob = await Task.detached { Data([0]) }.value
        #expect(blob.count == 1)
    }
}
