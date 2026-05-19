import Foundation
import Testing
@testable import PrismCore

struct PRMRecordingTests {
    @Test
    func `Stores URL and duration`() {
        let url = URL(fileURLWithPath: "/tmp/test.mov")
        let recording = PRMRecording(url: url, duration: 10.5)
        #expect(recording.url == url)
        #expect(recording.duration == 10.5)
    }

    @Test
    func `Equatable comparison`() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        #expect(PRMRecording(url: url, duration: 1) == PRMRecording(url: url, duration: 1))
    }
}
