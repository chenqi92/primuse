import Foundation

/// Constrains persisted remote paths to one canonical source root. Protocol
/// connectors use this before reads and destructive operations so stale or
/// tampered absolute paths cannot escape the source that owns them.
public struct RemotePathScopePolicy: Equatable, Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = Self.normalizeAbsolutePath(rootPath)
    }

    /// Resolves a stored absolute or source-relative path and rejects any path
    /// that can escape the configured root. Parent components are rejected
    /// before standardization so a persisted `..` can never be hidden by a
    /// later in-root component.
    public func resolvedPath(forStoredPath storedPath: String) -> String? {
        guard !Self.containsParentReference(storedPath) else { return nil }
        if storedPath.isEmpty || storedPath == "/" { return rootPath }

        let candidate: String
        if storedPath.hasPrefix("/") {
            candidate = Self.normalizeAbsolutePath(storedPath)
        } else if rootPath == "/" {
            candidate = Self.normalizeAbsolutePath("/\(storedPath)")
        } else {
            candidate = Self.normalizeAbsolutePath("\(rootPath)/\(storedPath)")
        }

        guard rootPath == "/"
                || candidate == rootPath
                || candidate.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    /// Converts a validated stored path to a slash-prefixed path relative to
    /// the configured root. This is the namespace expected by mounted NFS
    /// clients, whose `/` is already the selected export.
    public func relativePath(forStoredPath storedPath: String) -> String? {
        guard let resolved = resolvedPath(forStoredPath: storedPath) else { return nil }
        guard rootPath != "/" else { return resolved }
        guard resolved != rootPath else { return "/" }
        return String(resolved.dropFirst(rootPath.count))
    }

    /// Export identities must match exactly. Component-prefix collisions such
    /// as `/exports/music-old` are not children of `/exports/music` and a
    /// stored parent reference is never accepted as an alias of the same root.
    public func matchesRoot(_ storedRoot: String) -> Bool {
        guard !Self.containsParentReference(storedRoot) else { return false }
        return Self.normalizeAbsolutePath(storedRoot) == rootPath
    }

    private static func containsParentReference(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." }
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        var normalized = (absolutePath as NSString).standardizingPath
        if normalized.isEmpty || normalized == "." { return "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
