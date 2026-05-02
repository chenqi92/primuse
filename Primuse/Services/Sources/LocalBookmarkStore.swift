#if os(macOS)
import Foundation

/// Persists security-scoped bookmarks for user-chosen local folders so a
/// sandboxed macOS app can re-open them across launches without re-prompting.
///
/// Storage: bookmark blobs sit in UserDefaults keyed by sourceID. Resolved
/// URLs require `startAccessingSecurityScopedResource()` from the caller —
/// LocalFileSource owns that lifecycle.
enum LocalBookmarkStore {
    private static func defaultsKey(for sourceID: String) -> String {
        "primuse.localBookmark.\(sourceID)"
    }

    static func save(sourceID: String, url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: defaultsKey(for: sourceID))
    }

    /// Returns the resolved URL plus a flag for whether the caller still
    /// needs to call `startAccessingSecurityScopedResource()` (always true
    /// for security-scoped bookmarks). Returns nil when no bookmark is
    /// stored or the bookmark can't be resolved.
    static func resolve(sourceID: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(for: sourceID)) else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        if stale {
            // Refresh the stored bookmark — moving the folder rebuilds it.
            try? save(sourceID: sourceID, url: url)
        }
        return url
    }

    static func remove(sourceID: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: sourceID))
    }
}
#endif
