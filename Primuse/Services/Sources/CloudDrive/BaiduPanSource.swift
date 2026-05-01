import Foundation
import PrimuseKit

/// 百度网盘 Source — 使用百度开放平台 REST API
///
/// 注意：百度 xpan API 永远返回 HTTP 200，错误信息在 body 的 errno 里。
/// 必须显式检查 errno，否则错误会被静默吞掉（list 字段缺失 → 返回空数组 → 扫描 0 首）。
actor BaiduPanSource: MusicSourceConnector {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://pan.baidu.com"
    private static let oauthBase = "https://openapi.baidu.com/oauth/2.0"

    /// 单文件夹分页大小。百度 list 接口最大 1000。
    private static let pageSize = 1000

    /// 频控退避：每次 listFiles 之间至少间隔这么久，避免 errno 31034。
    /// 百度 file/list 免费档大约 5-10 QPS。100ms 留出 10 QPS 上限，
    /// 实测无 31034 命中；如果撞到了 31034 退避会自动兜底。
    private static let minRequestInterval: TimeInterval = 0.1

    /// errno 31034 命中时最多重试次数（指数退避）
    private static let rateLimitMaxRetries = 4

    /// 解析过的 dlink 缓存有效期。百度 dlink 实际有效 ~8 小时，但保守
    /// 一点用 30 分钟——避免 token 刷新或服务端策略变化时拿到老链接。
    /// 对一次播放来说远超够用：5MB 的歌按 256KB 一块拉 20 次，全程
    /// 命中缓存，省下 38 次 list/filemetas API 调用。
    private static let dlinkTTL: TimeInterval = 30 * 60

    private var lastRequestAt: Date?

    /// path → (dlink, expiry). Reset on token refresh because the access
    /// token is appended to the dlink at request time, but the dlink
    /// itself is signed for the user account; existing entries stay valid.
    private var dlinkCache: [String: (url: String, expiresAt: Date)] = [:]

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let dir = path.isEmpty ? "/" : path
        var all: [RemoteFileItem] = []
        var start = 0
        plog("☁️ Baidu listFiles dir=\(dir)")
        // 翻页：单文件夹超过 pageSize 时继续取，直到返回 < pageSize 为止
        while true {
            let page = try await listFilesPage(dir: dir, start: start)
            all.append(contentsOf: page)
            if page.count < Self.pageSize { break }
            start += Self.pageSize
        }
        plog("☁️ Baidu listFiles dir=\(dir) → \(all.count) items (\(all.filter{$0.isDirectory}.count) dirs)")
        return all
    }

    private func listFilesPage(dir: String, start: Int) async throws -> [RemoteFileItem] {
        let json = try await callAPI(
            base: "\(Self.apiBase)/rest/2.0/xpan/file",
            queryItems: [
                .init(name: "method", value: "list"),
                .init(name: "dir", value: dir),
                .init(name: "order", value: "name"),
                .init(name: "start", value: String(start)),
                .init(name: "limit", value: String(Self.pageSize)),
            ]
        )
        guard let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let p = item["path"] as? String,
                  let name = item["server_filename"] as? String else { return nil }
            let isDir = (item["isdir"] as? Int ?? 0) == 1
            let size = item["size"] as? Int64 ?? 0
            return RemoteFileItem(name: name, path: p, isDirectory: isDir, size: size, modifiedDate: nil)
        }
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let data = try await downloadFile(at: path)
        try helper.cacheData(data, for: path)
        return helper.cachedURL(for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let dlink = try await getDlink(for: path)
        let token = try await getToken()
        guard let url = URL(string: "\(dlink)&access_token=\(token)") else {
            throw CloudDriveError.invalidResponse
        }
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    // MARK: - Private

    private func downloadFile(at path: String) async throws -> Data {
        let token = try await getToken()
        let dlink = try await getDlink(for: path)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: URL(string: "\(dlink)&access_token=\(token)")!)
        return fileData
    }

    /// Resolve a remote path to a Baidu dlink URL (without access_token suffix).
    /// Two API calls (file/list + multimedia/filemetas) — cached for `dlinkTTL`
    /// so a single play session of N range requests doesn't burn 2N API calls.
    private func getDlink(for path: String) async throws -> String {
        if let cached = dlinkCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let listJson = try await callAPI(
            base: "\(Self.apiBase)/rest/2.0/xpan/file",
            queryItems: [
                .init(name: "method", value: "list"),
                .init(name: "dir", value: dir),
            ]
        )
        guard let entries = listJson["list"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["server_filename"] as? String) == name }),
              let fsId = entry["fs_id"] as? Int64 else {
            throw CloudDriveError.fileNotFound(path)
        }
        let metaJson = try await callAPI(
            base: "\(Self.apiBase)/rest/2.0/xpan/multimedia",
            queryItems: [
                .init(name: "method", value: "filemetas"),
                .init(name: "fsids", value: "[\(fsId)]"),
                .init(name: "dlink", value: "1"),
            ]
        )
        guard let metas = metaJson["list"] as? [[String: Any]],
              let dlink = metas.first?["dlink"] as? String else {
            throw CloudDriveError.fileNotFound(path)
        }
        dlinkCache[path] = (dlink, Date().addingTimeInterval(Self.dlinkTTL))
        return dlink
    }

    /// 统一封装百度 API 调用：节流 + errno 检查 + 31034 退避重试。
    /// queryItems 不要包含 access_token，本方法会自动附加最新 token。
    private func callAPI(
        base: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        var attempt = 0
        var backoff: TimeInterval = 0.5
        while true {
            try await throttle()
            let token = try await getToken()
            var components = URLComponents(string: base)!
            components.queryItems = queryItems + [.init(name: "access_token", value: token)]
            guard let url = components.url else { throw CloudDriveError.invalidResponse }

            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                plog("☁️ Baidu HTTP \(http.statusCode) url=\(base) body=\(body.prefix(500))")
                throw CloudDriveError.apiError(http.statusCode, body)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let errno = (json["errno"] as? Int) ?? 0
            if errno == 0 {
                return json
            }

            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            plog("☁️ Baidu errno=\(errno) attempt=\(attempt) url=\(base) body=\(bodyPreview)")

            // 31034: 接口频次超限 — 退避重试
            if errno == 31034, attempt < Self.rateLimitMaxRetries {
                plog("☁️ Baidu rate-limited, backoff \(backoff)s and retry")
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff *= 2
                attempt += 1
                continue
            }

            let msg = (json["errmsg"] as? String) ?? humanReadable(errno: errno)
            throw CloudDriveError.apiError(errno, msg)
        }
    }

    private func throttle() async throws {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let wait = Self.minRequestInterval - elapsed
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    private func humanReadable(errno: Int) -> String {
        switch errno {
        case -6: return "access_token 无效或未授权 netdisk scope (errno -6)"
        case 2: return "参数错误 (errno 2)"
        case 111: return "access_token 已过期 (errno 111)"
        case 31034: return "接口请求频次超限 (errno 31034)"
        case 42213: return "目录参数非法 (errno 42213)"
        default: return "百度网盘 errno \(errno)"
        }
    }

    private func getToken() async throws -> String {
        guard var tokens = await helper.tokenManager.getTokens() else { throw CloudDriveError.notAuthenticated }
        if tokens.isExpired {
            tokens = try await refreshToken(tokens)
            await helper.tokenManager.saveTokens(tokens)
        }
        return tokens.accessToken
    }

    private func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = await helper.tokenManager.getAppCredentials()
        guard let cid = creds?.clientId else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var c = URLComponents(string: "\(Self.oauthBase)/token")!
        c.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: rt), .init(name: "client_id", value: cid), .init(name: "client_secret", value: creds?.clientSecret ?? "")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let err = json["error"] as? String {
            throw CloudDriveError.tokenRefreshFailed("\(err): \(json["error_description"] as? String ?? "")")
        }
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "\(oauthBase)/authorize",
            tokenURL: "\(oauthBase)/token",
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: ["basic", "netdisk"],
            redirectURI: "https://baidu.callback.welape.com/",
            scopeSeparator: ",",
            usesPKCE: false,
            // 百度不支持自定义 scheme，redirect_uri 必须 https，
            // 由 baidu.callback.welape.com 上的中转页 JS 跳回 primuse:// 让 App 收到 code。
            explicitCallbackScheme: CloudOAuthConfig.callbackScheme
        )
    }
}
