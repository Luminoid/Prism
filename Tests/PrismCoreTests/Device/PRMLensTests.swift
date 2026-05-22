import Testing
@testable import PrismCore

struct PRMLensTests {
    @Test
    func `Snapping returns lower-bound match within tolerance`() {
        // FOV-derived focal length on virtual iPhone wide is around 28mm; tolerance picks 24.
        let lens = PRMLens(zoomFactor: 1.0, displayZoomFactor: 1.0, focalLength35mm: 28)
        let snapped = lens.snapping()
        #expect(snapped.focalLength35mm == 24)
    }

    @Test
    func `Snapping rounds video-FOV-cropped raw to marketing 24mm`() {
        // `videoFieldOfView` on iPhone 14/15/16/17 Pro wide reports the video-cropped FOV
        // (~10% narrower than photo FOV), so the FOV-derived raw lands at ~23.x mm.
        // Snapping must surface the marketing 24mm, not pick the cropped value.
        let lens = PRMLens(zoomFactor: 1.0, displayZoomFactor: 1.0, focalLength35mm: 23.5)
        let snapped = lens.snapping()
        #expect(snapped.focalLength35mm == 24)
    }

    @Test
    func `Snapping leaves out-of-tolerance values unchanged`() {
        let lens = PRMLens(zoomFactor: 1.0, displayZoomFactor: 1.0, focalLength35mm: 1000)
        let snapped = lens.snapping()
        #expect(snapped.focalLength35mm == 1000)
    }

    @Test
    func `Standard focal length set covers known phone cameras`() {
        let set = Set(PRMLens.standardFocalLengths)
        #expect(set.contains(13)) // iPhone 15 Pro ultra-wide
        #expect(set.contains(24)) // iPhone 15 wide
        #expect(set.contains(77)) // iPhone 15 Pro telephoto
        #expect(set.contains(120)) // iPhone 15 Pro Max 5x telephoto
    }
}
