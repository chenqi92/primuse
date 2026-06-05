import Foundation

/// 百度网盘流式解析(逻辑 mirror iOS BaiduPanSource)。
///
/// 三步:① list 父目录按文件名找 `fs_id` ② filemetas 取 dlink ③ HEAD `dlink&access_token`
/// (UA=pan.baidu.com,不自动跳转)读 302 Location 得 CDN 直链。播放需带 UA/Referer
/// (走 resource loader)。song.filePath = 百度网盘完整路径。
public actor BaiduPanStreamResolver: StreamResolver {
    static let apiBase = "https://pan.baidu.com"
    static let userAgent = "pan.baidu.com"
    static let referer = "https://pan.baidu.com/"
    static let pageSize = 1000

    private var accessTokens: [String: String] = [:]
    private let session: URLSession
    private let noRedirectSession: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        self.noRedirectSession = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func invalidateSession(sourceID: String) { accessTokens[sourceID] = nil }

    public func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        // 百度播放需 UA,不能直连;由 resolve 提供带头的结果。
        try await resolve(for: song, source: source, credential: credential).url
    }

    public func resolve(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> ResolvedStream {
        let cred = credential ?? SourceCredential()
        let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
        do {
            let cdn = try await resolveCdnURL(path: song.filePath, token: token)
            return ResolvedStream(url: cdn, headers: ["User-Agent": Self.userAgent, "Referer": Self.referer])
        } catch StreamResolveError.authFailed {
            let fresh = try await accessToken(for: source, cred: cred, forceRefresh: true)
            let cdn = try await resolveCdnURL(path: song.filePath, token: fresh)
            return ResolvedStream(url: cdn, headers: ["User-Agent": Self.userAgent, "Referer": Self.referer])
        }
    }

    // MARK: 解析链

    private func resolveCdnURL(path: String, token: String) async throws -> URL {
        let dlink = try await getDlink(path: path, token: token)
        guard let dlinkURL = URL(string: "\(dlink)&access_token=\(token)") else { throw StreamResolveError.cannotBuildURL }
        var head = URLRequest(url: dlinkURL)
        head.httpMethod = "HEAD"
        head.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        head.setValue(Self.referer, forHTTPHeaderField: "Referer")
        let (_, response) = try await noRedirectSession.data(for: head)
        guard let http = response as? HTTPURLResponse else { throw StreamResolveError.cannotBuildURL }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            guard let loc = http.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: loc, relativeTo: dlinkURL)?.absoluteURL else {
                throw StreamResolveError.cannotBuildURL
            }
            return url
        case 200:
            return dlinkURL
        case 401, 403, 410:
            throw StreamResolveError.authFailed
        default:
            throw StreamResolveError.badServerResponse(http.statusCode)
        }
    }

    private func getDlink(path: String, token: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = try await listEntries(in: dir, token: token)
        guard let fsId = Self.fsId(in: entries, name: name) else { throw StreamResolveError.cannotBuildURL }

        let meta = try await callAPI(base: "\(Self.apiBase)/rest/2.0/xpan/multimedia", token: token, query: [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "fsids", value: "[\(fsId)]"),
            URLQueryItem(name: "dlink", value: "1"),
        ])
        guard let dlink = Self.dlink(in: meta) else { throw StreamResolveError.cannotBuildURL }
        return dlink
    }

    private func listEntries(in dir: String, token: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var start = 0
        while true {
            let json = try await callAPI(base: "\(Self.apiBase)/rest/2.0/xpan/file", token: token, query: [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ])
            let entries = json["list"] as? [[String: Any]] ?? []
            all.append(contentsOf: entries)
            if entries.count < Self.pageSize { break }
            start += Self.pageSize
        }
        return all
    }

    /// 百度 API 永远 200,错误在 body 的 errno。附加 access_token。
    private func callAPI(base: String, token: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard var comp = URLComponents(string: base) else { throw StreamResolveError.cannotBuildURL }
        comp.queryItems = query + [URLQueryItem(name: "access_token", value: token)]
        guard let url = comp.url else { throw StreamResolveError.cannotBuildURL }
        let (data, _) = try await session.data(from: url)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let errno = json["errno"] as? Int, errno != 0 {
            if errno == 111 || errno == -6 { throw StreamResolveError.authFailed }   // token 失效
            throw StreamResolveError.badServerResponse(errno)
        }
        return json
    }

    private func accessToken(for source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = accessTokens[source.id] { return cached }
        let token: String
        if !forceRefresh, let t = cred.token, !t.isEmpty {
            token = t
        } else {
            guard let rt = cred.refreshToken, let cid = cred.clientID else { throw StreamResolveError.missingCredential }
            var comp = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
            comp.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: rt),
                URLQueryItem(name: "client_id", value: cid),
                URLQueryItem(name: "client_secret", value: cred.clientSecret ?? ""),
            ]
            let (data, _) = try await session.data(from: comp.url!)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = json["access_token"] as? String else { throw StreamResolveError.authFailed }
            token = t
        }
        accessTokens[source.id] = token
        return token
    }

    // MARK: 纯函数(可单测)

    static func fsId(in entries: [[String: Any]], name: String) -> Int64? {
        guard let entry = entries.first(where: { ($0["server_filename"] as? String) == name }) else { return nil }
        if let v = entry["fs_id"] as? Int64 { return v }
        if let v = entry["fs_id"] as? Int { return Int64(v) }
        return (entry["fs_id"] as? NSNumber)?.int64Value
    }

    static func dlink(in filemetas: [String: Any]) -> String? {
        guard let list = filemetas["list"] as? [[String: Any]] else { return nil }
        return list.first?["dlink"] as? String
    }
}

/// 不自动跟随重定向,以便读取 302 的 Location(百度 dlink → CDN)。
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
