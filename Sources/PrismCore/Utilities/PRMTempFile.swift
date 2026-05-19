import Foundation

/// Temporary file utilities scoped to a `Prism/` subdirectory.
///
/// All files are written under `<tmp>/Prism/`, so ``clearAll()`` is safe to call without
/// nuking unrelated tmp content (the old `PRMFileHelper` cleaned the entire tmp directory).
public enum PRMTempFile: Sendable {
    /// Directory name (inside `NSTemporaryDirectory()`) used for Prism's tmp files.
    public static let directoryName = "Prism"

    /// The absolute path of Prism's tmp directory. Created lazily.
    public static var directoryURL: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(directoryName, isDirectory: true)
        ensureDirectoryExists(at: url)
        return url
    }

    /// Returns a unique URL under `<tmp>/Prism/` with the given extension.
    ///
    /// - Parameter fileExtension: Extension without leading dot (e.g., `"mov"`, `"jpg"`).
    public static func url(withExtension fileExtension: String) -> URL {
        directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    /// Removes every file in `<tmp>/Prism/`. Best-effort — failures are logged but not thrown,
    /// because callers typically invoke this during teardown when nothing actionable can be
    /// done on failure (disk full / permission revoked / in-use by another process).
    public static func clearAll() {
        let fileManager = FileManager.default
        let url = directoryURL
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            PRMLogger.general.warning(
                "PRMTempFile.clearAll: cannot list \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for fileURL in contents {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                PRMLogger.general.warning(
                    "PRMTempFile.clearAll: cannot remove \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Removes a single file. Returns `true` if the file existed and was removed.
    /// Failures are logged at warning level.
    @discardableResult
    public static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            PRMLogger.general.warning(
                "PRMTempFile.remove: cannot remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Private

    private static func ensureDirectoryExists(at url: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            PRMLogger.general.error(
                "PRMTempFile: cannot create directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
