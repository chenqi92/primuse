import Foundation

/// Resolves an absolute file path persisted inside an older iOS app-data
/// container. Reinstalling an app changes the container UUID while restored
/// Application Support, Caches and Documents content keeps the same relative
/// location. Only known Primuse-owned roots are rebased, and a URL is returned
/// only when the direct or rebased target exists.
public enum PrimuseSandboxPathResolver {
    public static func existingURL(
        forStoredAbsolutePath storedPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard storedPath.hasPrefix("/") else { return nil }

        let directURL = URL(fileURLWithPath: storedPath).standardizedFileURL
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let roots: [(marker: String, currentRoot: URL)] = [
            (
                "/Library/Application Support/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .applicationSupportDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Library/Caches/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Documents/LocalMusic/",
                fileManager
                    .primuseDirectoryURL(for: .documentDirectory)
                    .appendingPathComponent("LocalMusic", isDirectory: true)
            ),
        ]

        for root in roots {
            guard let markerRange = storedPath.range(of: root.marker) else { continue }
            let relativePath = String(storedPath[markerRange.upperBound...])
            let standardizedRoot = root.currentRoot.standardizedFileURL
            let candidate = relativePath.isEmpty
                ? standardizedRoot
                : standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
            let rootPrefix = standardizedRoot.path.hasSuffix("/")
                ? standardizedRoot.path
                : standardizedRoot.path + "/"
            guard (candidate.path == standardizedRoot.path || candidate.path.hasPrefix(rootPrefix)),
                  fileManager.fileExists(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }
}
