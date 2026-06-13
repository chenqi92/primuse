import Foundation

// WebDAV / UPnP 在 tvOS 上本质是纯 HTTP,无需原生协议库:WebDAV 文件就是 GET + Range
// 可取(Basic Auth),UPnP 的 song.filePath 本就是 media server 暴露的 http(s) 直链。
// 故 tvOS 直接走现成的 AVPlayer + TVStreamResourceLoader(HTTP),不再经 iPhone 中继。

/// WebDAV:拼 `scheme://host:port/basePath/filePath`,带 Basic Auth 头。
public struct WebDavStreamResolver: StreamResolver {
    public init() {}

    public func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        var comps = URLComponents()
        comps.scheme = source.useSsl ? "https" : "http"
        comps.host = source.host
        let defaultPort = source.useSsl ? 443 : 80
        if let p = source.port, p != defaultPort { comps.port = p }
        comps.path = Self.joinPath(source.basePath, song.filePath)
        guard let url = comps.url else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    public func resolve(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> ResolvedStream {
        let url = try await streamURL(for: song, source: source, credential: credential)
        var headers: [String: String] = [:]
        let user = credential?.username ?? source.username ?? ""
        let pass = credential?.password ?? ""
        if !user.isEmpty || !pass.isEmpty {
            let token = Data("\(user):\(pass)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(token)"
        }
        return ResolvedStream(url: url, headers: headers)
    }

    /// 把 basePath + 相对 filePath 拼成单斜杠分隔的绝对路径(未编码,交给 URLComponents 编码)。
    static func joinPath(_ base: String?, _ rel: String) -> String {
        let slashes = CharacterSet(charactersIn: "/")
        let parts = [base ?? "", rel]
            .map { $0.trimmingCharacters(in: slashes) }
            .filter { !$0.isEmpty }
        return "/" + parts.joined(separator: "/")
    }
}

/// UPnP/DLNA:song.filePath 已是 media server 的 http(s) 直链,直接播。
public struct UPnPStreamResolver: StreamResolver {
    public init() {}

    public func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        guard let url = URL(string: song.filePath), url.scheme?.hasPrefix("http") == true else {
            throw StreamResolveError.cannotBuildURL
        }
        return url
    }
}
