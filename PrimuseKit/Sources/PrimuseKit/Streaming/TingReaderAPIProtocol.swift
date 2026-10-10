import Foundation

/// Ting Reader 的地址与引用约定。
///
/// 一章就是服务器上的一个音频文件,在 Primuse 里是一首歌。歌曲路径是不含服务器文件路径的合成引用
/// (`/tingreader/books/{bookID}/chapters/{chapterID}.{ext}`),播放时回到 `/api/stream/{chapterID}`
/// 并附 Bearer token;上报进度要书 id,所以它也在路径里。
public enum TingReaderAPIProtocol {
    public static let defaultPort = 3000

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

    /// `path` 是服务器上的完整路径(`/api/books`、`/api/auth/login`),前面只加反向代理前缀。
    /// 里面的 id 段已经用 `encodedPathComponent` 转义过,所以按已转义的路径拼,不能再让
    /// `URLComponents.path` 转一遍(`%20` 会变成 `%2520`)。
    public static func endpointURL(
        serverBaseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let prefix = normalizedPrefix(components.percentEncodedPath)
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = endpoint.isEmpty ? prefix : "\(prefix)/\(endpoint)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        return FormSafeQueryURLBuilder.url(from: components)
    }

    /// 一章的音频。本地与 WebDAV 存储库回原始字节并支持 Range;不转码。
    public static func streamPath(chapterID: String) -> String {
        "/api/stream/\(encodedPathComponent(chapterID))"
    }

    public static func streamURL(serverBaseURL: URL, chapterID: String) -> URL? {
        endpointURL(serverBaseURL: serverBaseURL, path: streamPath(chapterID: chapterID))
    }

    // MARK: - Track references

    public struct TrackReference: Equatable, Sendable, Hashable {
        public let bookID: String
        public let chapterID: String
        public let fileExtension: String

        public init(bookID: String, chapterID: String, fileExtension: String) {
            self.bookID = bookID
            self.chapterID = chapterID
            self.fileExtension = fileExtension
        }
    }

    private static let trackPrefix = "/tingreader/books/"

    public static func trackPath(bookID: String, chapterID: String, fileExtension: String) -> String {
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return "\(trackPrefix)\(encodedPathComponent(bookID))/chapters/\(encodedPathComponent(chapterID)).\(suffix.isEmpty ? "bin" : suffix)"
    }

    public static func trackReference(from path: String) -> TrackReference? {
        guard path.hasPrefix(trackPrefix) else { return nil }
        let parts = path.dropFirst(trackPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "chapters" else { return nil }
        let bookID = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let leaf = String(parts[2])
        let fileExtension = (leaf as NSString).pathExtension.lowercased()
        let rawID = (leaf as NSString).deletingPathExtension
        let chapterID = rawID.removingPercentEncoding ?? rawID
        guard !bookID.isEmpty, !chapterID.isEmpty else { return nil }
        return TrackReference(bookID: bookID, chapterID: chapterID, fileExtension: fileExtension)
    }

    /// 一章在歌曲路径末段里的样子(`ServerPlaylistIdentity.serverItemID(fromFilePath:)` 读出来的就是它),
    /// 书单镜像按它把章节对回本机的歌。
    public static func serverItemID(chapterID: String) -> String {
        encodedPathComponent(chapterID)
    }

    /// 服务器上一章的路径(本地路径、WebDAV 路径或 RSS 里的音频地址)对应的音频后缀。
    /// `.strm` 只是一张指向别处的便条,真正的格式要播放时才知道;Primuse 自己也认 `.strm`,
    /// 留着它会被当成便条去解析,所以和认不出的后缀一样记成 `bin`。
    public static func audioFileExtension(forServerPath path: String) -> String {
        var candidate = path
        if let components = URLComponents(string: path), components.scheme != nil {
            candidate = components.path
        }
        let ext = (candidate as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext != "strm", ext.count <= 5,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return "bin"
        }
        return ext
    }

    // MARK: - Cover references

    /// 封面不存绝对 URL:取封面要带 token,token 会过期。服务端的封面字段可能是存储库里的
    /// 文件路径,也可能是刮削来的外链,都经 `/api/proxy/cover` 由服务器代取,所以引用里
    /// 记下书、存储库和那个原始值。
    public struct CoverReference: Equatable, Sendable {
        public let bookID: String
        public let libraryID: String
        public let path: String

        public init(bookID: String, libraryID: String, path: String) {
            self.bookID = bookID
            self.libraryID = libraryID
            self.path = path
        }
    }

    public static func coverReference(bookID: String, libraryID: String, coverPath: String) -> String {
        let encoded = Data(coverPath.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "tingreader:cover:\(encodedPathComponent(bookID)):\(encodedPathComponent(libraryID)):\(encoded)"
    }

    public static func coverReference(from reference: String) -> CoverReference? {
        let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "tingreader", parts[1] == "cover", !parts[4].isEmpty else {
            return nil
        }
        let bookID = String(parts[2]).removingPercentEncoding ?? String(parts[2])
        let libraryID = String(parts[3]).removingPercentEncoding ?? String(parts[3])
        var base64 = String(parts[4])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard !bookID.isEmpty,
              let data = Data(base64Encoded: base64),
              let path = String(data: data, encoding: .utf8),
              !path.isEmpty else { return nil }
        return CoverReference(bookID: bookID, libraryID: libraryID, path: path)
    }

    /// 服务器代取封面的查询参数,和它自带网页端的写法一致。
    public static func coverProxyQueryItems(for cover: CoverReference) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "path", value: cover.path)]
        if !cover.libraryID.isEmpty { items.append(URLQueryItem(name: "library_id", value: cover.libraryID)) }
        items.append(URLQueryItem(name: "book_id", value: cover.bookID))
        return items
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
