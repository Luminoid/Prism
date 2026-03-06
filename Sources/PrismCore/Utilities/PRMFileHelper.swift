import Foundation

/// File utilities for temporary capture output.
public enum PRMFileHelper: Sendable {
    // MARK: - Temporary Files

    /// Returns a unique URL in the temporary directory with the given extension.
    ///
    /// - Parameter fileExtension: The file extension (e.g. `"jpg"`, `"mov"`). Do not include a leading dot.
    /// - Returns: A `URL` pointing to a unique file in `NSTemporaryDirectory()`.
    public static func temporaryFileURL(withExtension fileExtension: String) -> URL {
        let directory = NSTemporaryDirectory()
        let fileName = UUID().uuidString
        return URL(fileURLWithPath: directory)
            .appendingPathComponent(fileName)
            .appendingPathExtension(fileExtension)
    }

    /// Removes all files in the temporary directory whose names match `UUID` format.
    ///
    /// This is a best-effort cleanup — failures are silently ignored.
    public static func clearTemporaryFiles() {
        let fileManager = FileManager.default
        let tmpDirectory = NSTemporaryDirectory()
        guard let contents = try? fileManager.contentsOfDirectory(atPath: tmpDirectory) else { return }
        for fileName in contents {
            let filePath = (tmpDirectory as NSString).appendingPathComponent(fileName)
            try? fileManager.removeItem(atPath: filePath)
        }
    }
}
