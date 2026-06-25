import Foundation
import PrimuseKit

/// 115 网盘 Source — 115 开放平台 OpenAPI。
///
/// ⚠️ 占位实现:端点与字段名按 115 开放平台公开资料(proapi.115.com/open、
/// passportapi.115.com/open)填写,需在拿到开发者 client_id 后对照官方文档
/// (https://www.yuque.com/115yun/open)核对并联调。结构、token 刷新、列目录、
/// 取下载直链的整体流程已就位,照搬阿里云盘 connector 模式。
///
/// 关键差异(待联调确认):
///  · 115 的初次授权用「设备码 + 二维码 PKCE」流程(authDeviceCode →
///    deviceCodeToToken),不是浏览器重定向;当前先复用重定向式 oauthConfig
///    占位,正式接入时需补设备码授权 UI(或让用户粘贴 refresh_token)。
///  · refreshToken 不需要 client_secret(115 按 IP 限流)。
///  · 列表项的目录/文件区分与 id 字段(fid / cid / pc)以官方文档为准。
actor U115Source: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper

    /// pickCode → (downloadURL, expiry)。115 直链有时效,缓存 20 分钟省去重复换链。
    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 20 * 60

    private static let apiBase = "https://proapi.115.com/open"
    private static let passportBase = "https://passportapi.115.com/open"
    /// 115 直链对 UA 敏感,下载请求需带与换链一致的 UA。
    private static let userAgent = "Mozilla/5.0 Primuse/1.0"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        _ = try await getToken()
    }

    func disconnect() async {}

    /// 用户 UID(跨 token 刷新稳定),用于把多个挂载关联到同一 115 账户。
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/user/info")!,
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let payload = json["data"] as? [String: Any] ?? json
        if let uid = payload["user_id"] { return String(describing: uid) }
        if let uid = payload["uid"] { return String(describing: uid) }
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        // path 为目录 id;根目录用 "0"。
        let cid = path.isEmpty || path == "/" ? "0" : path
        var all: [RemoteFileItem] = []
        var offset = 0
        let limit = 1000
        while true {
            let token = try await getToken()
            var comps = URLComponents(string: "\(Self.apiBase)/ufile/files")!
            comps.queryItems = [
                URLQueryItem(name: "cid", value: cid),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "show_dir", value: "1"),
            ]
            let listURL = comps.url!
            let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(url: listURL, accessToken: tok)
            }
            guard http.statusCode == 200 else {
                throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let items = json["data"] as? [[String: Any]] ?? []
            for item in items {
                guard let name = item["fn"] as? String ?? item["n"] as? String else { continue }
                // fc == "0" 目录 / "1" 文件(以官方文档为准)。
                let isDir = (item["fc"] as? String == "0") || (item["fc"] as? Int == 0)
                let size = (item["fs"] as? Int64) ?? Int64(item["fs"] as? String ?? "0") ?? 0
                let sha1 = item["sha1"] as? String
                if isDir {
                    // 目录:用目录 id 作为后续 listFiles 的 path。
                    let dirID = (item["fid"] as? String) ?? (item["cid"] as? String) ?? ""
                    guard !dirID.isEmpty, dirID != "0" else { continue }
                    all.append(RemoteFileItem(name: name, path: dirID, isDirectory: true,
                                              size: 0, modifiedDate: nil, revision: nil))
                } else {
                    // 文件:用 pick_code(pc)作为 path,取直链时需要。
                    guard let pc = item["pc"] as? String, !pc.isEmpty else { continue }
                    all.append(RemoteFileItem(name: name, path: pc, isDirectory: false,
                                              size: size, modifiedDate: nil, revision: sha1))
                }
            }
            if items.count < limit { break }
            offset += limit
        }
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (fileData, _) = try await URLSession(configuration: config).data(for: req)
        try helper.cacheData(fileData, for: path)
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
        let url = try await getDownloadURL(for: path)
        return try await helper.rangeRequest(url: url, offset: offset, length: length, userAgent: Self.userAgent)
    }

    // MARK: - 私有

    /// path 是文件的 pick_code;调 downurl 换直链。
    private func getDownloadURL(for pickCode: String) async throws -> URL {
        if let cached = downloadURLCache[pickCode], cached.expiresAt > Date() {
            return cached.url
        }
        let token = try await getToken()
        let body = CloudDriveHelper.formURLEncodedBody([URLQueryItem(name: "pick_code", value: pickCode)])
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/ufile/downurl")!,
                method: "POST", body: body,
                contentType: "application/x-www-form-urlencoded", accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // data 以 file_id 为键:{ "<file_id>": { "url": { "url": "https://..." } } }
        guard let payload = json["data"] as? [String: Any],
              let first = payload.values.first as? [String: Any],
              let urlField = first["url"] as? [String: Any],
              let link = urlField["url"] as? String,
              let fileURL = URL(string: link) else {
            throw CloudDriveError.fileNotFound(pickCode)
        }
        downloadURLCache[pickCode] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
        return fileURL
    }

    private func getToken() async throws -> String {
        // proactive 路径: 本地标记过期才刷新, 与 reactive(401)路径共享 CloudTokenManager
        // 里的同一个 in-flight 去重任务, 避免并发刷新把轮换型 refresh_token 作废。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    /// 115 刷新只需 refresh_token,不需要 client_secret。
    // nonisolated: 只用 helper(Sendable)/静态常量/URLSession, 不碰可变 actor 状态,
    // 这样能作为 @Sendable 闭包传给 tokenManager.refreshDeduped / withTokenRetry。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let body = CloudDriveHelper.formURLEncodedBody([URLQueryItem(name: "refresh_token", value: rt)])
        var request = URLRequest(url: URL(string: "\(Self.passportBase)/refreshToken")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let payload = json["data"] as? [String: Any] ?? json
        guard let at = payload["access_token"] as? String else {
            throw CloudDriveError.tokenRefreshFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let expiresIn = payload["expires_in"] as? TimeInterval ?? 7200
        return .init(accessToken: at,
                     refreshToken: payload["refresh_token"] as? String ?? rt,
                     expiresAt: Date().addingTimeInterval(expiresIn),
                     extra: tokens.extra)
    }

    /// 授权码模式(浏览器重定向):用于 iOS,以及 macOS 不走扫码时的路径。
    /// 115 的 redirect_uri 必须是注册过的 https 域名(不收自定义 scheme),故用 welape
    /// https 中转页,页面再深链回 `primuse://pan115/callback`(靠 explicitCallbackScheme
    /// 让 ASWebAuthenticationSession 监听 primuse scheme)。
    /// 注意:tokenURL 是 authCodeToToken(非扫码用的 deviceCodeToToken),且不用 PKCE。
    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "\(passportBase)/authorize",
            tokenURL: "\(passportBase)/authCodeToToken",
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: [],
            redirectURI: "https://115pan.callback.welape.com/",
            usesPKCE: false,
            explicitCallbackScheme: CloudOAuthConfig.callbackScheme
        )
    }
}
