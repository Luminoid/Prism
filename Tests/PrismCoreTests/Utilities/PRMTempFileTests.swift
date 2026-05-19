import Foundation
import Testing
@testable import PrismCore

struct PRMTempFileTests {
    @Test
    func `Generates a unique URL in Prism/ subdirectory`() {
        let url = PRMTempFile.url(withExtension: "jpg")
        #expect(url.pathComponents.contains("Prism"))
        #expect(url.pathExtension == "jpg")
    }

    @Test
    func `Subdirectory is created lazily on first access`() {
        let url = PRMTempFile.directoryURL
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func `clearAll removes only Prism-scoped files`() throws {
        let test1 = PRMTempFile.url(withExtension: "txt")
        try Data("hello".utf8).write(to: test1)
        #expect(FileManager.default.fileExists(atPath: test1.path))
        PRMTempFile.clearAll()
        #expect(!FileManager.default.fileExists(atPath: test1.path))
    }

    @Test
    func `remove(url:) deletes specific file`() throws {
        let url = PRMTempFile.url(withExtension: "txt")
        try Data("hello".utf8).write(to: url)
        #expect(PRMTempFile.remove(url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
