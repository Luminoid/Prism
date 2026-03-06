import Foundation
import Testing
@testable import PrismCore

// MARK: - PRMFileHelperTests

@Suite("PRMFileHelper")
struct PRMFileHelperTests {
    // MARK: - Temporary File URL

    @Test("Temporary file URL has correct extension")
    func temporaryFileExtension() {
        let url = PRMFileHelper.temporaryFileURL(withExtension: "mov")
        #expect(url.pathExtension == "mov")
    }

    @Test("Temporary file URL is in temp directory")
    func temporaryFileInTempDirectory() {
        let url = PRMFileHelper.temporaryFileURL(withExtension: "jpg")
        #expect(url.path.hasPrefix(NSTemporaryDirectory()))
    }

    @Test("Temporary file URLs are unique")
    func temporaryFileUniqueness() {
        let url1 = PRMFileHelper.temporaryFileURL(withExtension: "jpg")
        let url2 = PRMFileHelper.temporaryFileURL(withExtension: "jpg")
        #expect(url1 != url2)
    }

    @Test("Temporary file URL with different extensions")
    func differentExtensions() {
        let jpgURL = PRMFileHelper.temporaryFileURL(withExtension: "jpg")
        let movURL = PRMFileHelper.temporaryFileURL(withExtension: "mov")
        #expect(jpgURL.pathExtension == "jpg")
        #expect(movURL.pathExtension == "mov")
    }

    // MARK: - Clear Temporary Files

    @Test("Clear temporary files does not throw")
    func clearTemporaryFilesNoThrow() {
        // Best-effort cleanup — should never throw
        PRMFileHelper.clearTemporaryFiles()
    }

    @Test("Clear temporary files removes created temp file")
    func clearRemovesCreatedFile() throws {
        let url = PRMFileHelper.temporaryFileURL(withExtension: "txt")
        try Data("test".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        PRMFileHelper.clearTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
