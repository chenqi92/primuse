import Foundation

/// Audiobookshelf 的地址与引用约定。
///
/// 书的每个音频文件、播客的每一集在 Primuse 里各是一首歌,用不含服务器文件路径的合成引用
/// (`/audiobookshelf/items/{itemID}/files/{ino}.{ext}`、`…/episodes/{episodeID}.{ext}`),
/// 播放时回到 `/api/items/{id}/file/{ino}` 并附 Bearer token。
public enum AudiobookshelfAPIProtocol {
    public static let defaultPort = 13378

    public static func serverBaseURL(
        host rawHost: String,
        port: Int?,
        useSSL: Bool,
        basePath: String? = nil
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let defaultScheme = useSSL ? "https" : "http"
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if isIPv6Literal(trimmed) {
            let literal = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            candidate = "\(defaultScheme)://[\(literal)]"
        } else {
            candidate = "\(defaultScheme)://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              components.host?.isEmpty == false else { return nil }
        if components.scheme?.isEmpty != false { components.scheme = defaultScheme }
        if components.port == nil, let port, port > 0 { components.port = port }
        if components.path.isEmpty || components.path == "/" {
            components.path = normalizedPrefix(basePath ?? "")
        } else {
            components.path = normalizedPrefix(components.path)
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// `path` 是服务器上的完整路径(`/api/libraries`、`/login`、`/ping`),不自动加前缀:
    /// Audiobookshelf 的登录与状态接口不在 `/api` 下。
    public static func endpointURL(
        serverBaseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let prefix = normalizedPrefix(components.path)
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = endpoint.isEmpty ? prefix : "\(prefix)/\(endpoint)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        return FormSafeQueryURLBuilder.url(from: components)
    }

    /// 原始文件,支持 Range;服务端不转码。
    public static func fileURL(serverBaseURL: URL, itemID: String, ino: String) -> URL? {
        endpointURL(
            serverBaseURL: serverBaseURL,
            path: "/api/items/\(encodedPathComponent(itemID))/file/\(encodedPathComponent(ino))"
        )
    }

    public static func coverURL(serverBaseURL: URL, itemID: String, width: Int? = nil) -> URL? {
        endpointURL(
            serverBaseURL: serverBaseURL,
            path: "/api/items/\(encodedPathComponent(itemID))/cover",
            queryItems: width.map { [URLQueryItem(name: "width", value: String($0))] } ?? []
        )
    }

    // MARK: - Track references

    public enum TrackKind: Equatable, Sendable, Hashable {
        /// 书里的一个音频文件,按文件 inode 号取。
        case file(ino: String)
        /// 播客的一集。
        case episode(id: String)
    }

    public struct TrackReference: Equatable, Sendable, Hashable {
        public let itemID: String
        public let kind: TrackKind
        public let fileExtension: String

        public init(itemID: String, kind: TrackKind, fileExtension: String) {
            self.itemID = itemID
            self.kind = kind
            self.fileExtension = fileExtension
        }
    }

    private static let trackPrefix = "/audiobookshelf/items/"

    public static func trackPath(itemID: String, kind: TrackKind, fileExtension: String) -> String {
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let leaf: String
        switch kind {
        case .file(let ino):
            leaf = "files/\(encodedPathComponent(ino))"
        case .episode(let id):
            leaf = "episodes/\(encodedPathComponent(id))"
        }
        return "\(trackPrefix)\(encodedPathComponent(itemID))/\(leaf).\(suffix.isEmpty ? "bin" : suffix)"
    }

    public static func trackReference(from path: String) -> TrackReference? {
        guard path.hasPrefix(trackPrefix) else { return nil }
        let parts = path.dropFirst(trackPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let itemID = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let leaf = String(parts[2])
        let fileExtension = (leaf as NSString).pathExtension.lowercased()
        let rawID = (leaf as NSString).deletingPathExtension
        let id = rawID.removingPercentEncoding ?? rawID
        guard !itemID.isEmpty, !id.isEmpty else { return nil }
        switch parts[1] {
        case "files":
            return TrackReference(itemID: itemID, kind: .file(ino: id), fileExtension: fileExtension)
        case "episodes":
            return TrackReference(itemID: itemID, kind: .episode(id: id), fileExtension: fileExtension)
        default:
            return nil
        }
    }

    // MARK: - Cover references

    /// 封面不存绝对 URL:取封面要带 token,token 会过期,所以存一个不透明引用,
    /// 由连接器带着当时的会话去取。
    public static func coverReference(itemID: String, updatedAt: Date?) -> String {
        let stamp = updatedAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
        return "audiobookshelf:cover:\(itemID):\(stamp)"
    }

    public static func coverItemID(fromReference reference: String) -> String? {
        let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "audiobookshelf", parts[1] == "cover", !parts[2].isEmpty else {
            return nil
        }
        return String(parts[2])
    }

    // MARK: - Helpers

    private static func normalizedPrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : "/\(trimmed)"
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return candidate.contains(":") && !candidate.contains("/")
    }

    static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
