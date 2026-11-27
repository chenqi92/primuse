import Foundation

/// Keeps WebDAV response paths in the source-relative namespace even when a
/// reverse proxy exposes the upstream `/dav` root under a longer public path.
/// Some servers return upstream hrefs in PROPFIND responses, while clients
/// resolve operations against the configured public base URL.
public struct WebDAVPathPolicy: Equatable, Sendable {
    public let basePath: String

    public init(basePath: String?) {
        self.basePath = Self.normalizeAbsolutePath(basePath ?? "/")
    }

    /// Converts a PROPFIND `<D:href>` to a source-relative path, resolving a
    /// relative reference against the configured base URL.
    ///
    /// Only the path is read. RFC 4918 lets a server answer with an absolute
    /// path or a full URI, and a server behind a reverse proxy, a tunnel or a
    /// CDN routinely builds that URI from its own upstream address — an href of
    /// `http://192.168.1.10:5005/dav/Music/` while the client is connected to
    /// `https://dav.example.com`. The href's scheme, host and port never
    /// address a request, because every follow-up call is built from the
    /// configured base URL plus the source path returned here, so a mismatch
    /// says nothing about whether the entry belongs to this source. Scope is
    /// enforced by `sourcePath(forServerPath:)`, which keeps the result inside
    /// the configured root and rejects parent references.
    public func sourcePath(forHref href: String, baseURL: URL) -> String? {
        let escapedHref = href.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: " ").inverted
        ) ?? href
        guard let absoluteURL = URL(string: escapedHref, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return sourcePath(forServerPath: absoluteURL.standardized.path)
    }

    /// Converts an absolute server href/path to a source-relative path. The
    /// full configured root is preferred; its final component is also accepted
    /// for reverse proxies that expose an upstream WebDAV root such as `/dav`
    /// without rewriting XML response bodies.
    public func sourcePath(forServerPath serverPath: String) -> String? {
        let decodedPath = serverPath.removingPercentEncoding ?? serverPath
        guard decodedPath.hasPrefix("/"),
              !Self.containsParentReference(decodedPath) else {
            return nil
        }

        let targetPath = Self.normalizeAbsolutePath(decodedPath)
        guard basePath != "/" else { return targetPath }

        var candidateRoots = [basePath]
        if let leaf = basePath.split(separator: "/").last {
            let upstreamRoot = "/\(leaf)"
            if upstreamRoot != basePath {
                candidateRoots.append(upstreamRoot)
            }
        }
        for candidateRoot in candidateRoots {
            if targetPath == candidateRoot {
                return "/"
            }
            if targetPath.hasPrefix(candidateRoot + "/") {
                return String(targetPath.dropFirst(candidateRoot.count))
            }
        }
        return nil
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
