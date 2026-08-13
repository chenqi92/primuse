import CryptoKit
import Foundation
import PrimuseKit

/// 123 云盘 Source — 123 开放平台 OpenAPI(open-api.123pan.com),第三方挂载应用 OAuth 模式。
///
/// 用户在 App 内通过标准 OAuth 授权码流程授权自己的 123 账号:
///   1. 跳 https://yun.123pan.com/auth(内置 appId 作 client_id, scope 固定
///      `user:base,file:all:read,file:all:write`)
///   2. 用户授权后直接回调已登记的 `primuse://oauth/123pan/callback`
///   3. POST /api/v1/oauth2/access_token 用 code 换 access_token + refresh_token(90 天)
/// 之后所有 API 带头 `Platform: open_platform` + `Authorization: Bearer <token>`,
/// 响应统一 `{code:0, message, data}`(code==0 成功; 401 token 失效; 429 限流)。
///
/// 刮削的封面 / 歌词通过 V2 单步上传(/upload/v2/file/single/create)回写到源歌曲
/// 同目录(用源文件真实名 + `-cover.jpg` / `.lrc`),重扫时按同名读回,多设备共享。
///
/// 123 用「文件 ID」而非层级路径标识文件 —— `RemoteFileItem.path` / `Song.filePath`
/// 存的是 fileId 字符串。sidecar 写入时 SidecarWriteService 传来的 path 形如
/// `"{fileId}-cover.jpg"`,这里反解 fileId → 查文件详情拿真实名 + 父目录 → 上传。
actor Pan123Source: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削封面/歌词回写 123 云盘
    nonisolated let preferredDeleteBatchSize = 100
    private let helper: CloudDriveHelper

    private static let apiBase = "https://open-api.123pan.com"
    private static let authURL = "https://yun.123pan.com/auth"
    private static let tokenURL = "\(apiBase)/api/v1/oauth2/access_token"
    /// 单步上传的兜底域名 —— 正常应走 /upload/v2/file/domain 动态获取,失败时用这个。
    private static let fallbackUploadDomain = "https://openapi-upload.123pan.com"
    static let redirectURI = "\(CloudOAuthConfig.callbackScheme)://oauth/123pan/callback"

    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 20 * 60
    private var cachedUploadDomain: (value: String, expiresAt: Date)?
    private static let uploadDomainTTL: TimeInterval = 30 * 60

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    /// 123 `/api/v1/user/info` 返回 `data.uid` —— 跨刷新 / 跨设备稳定的账号标识。
    func accountIdentifier() async throws -> String {
        let json = try await authedRequest("/api/v1/user/info")
        let data = json["data"] as? [String: Any] ?? [:]
        if let uid = Self.intValue(data["uid"]) { return String(uid) }
        if let uid = data["uid"] as? String, !uid.isEmpty { return uid }
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parent = path.isEmpty || path == "/" ? "0" : path
        var all: [RemoteFileItem] = []
        var lastFileId: String? = nil
        var seenLastFileIDs: Set<String> = []
        while true {
            var query = "/api/v2/file/list?parentFileId=\(parent)&limit=100"
            if let l = lastFileId { query += "&lastFileId=\(l)" }
            let json = try await authedRequest(query)
            guard let data = json["data"] as? [String: Any],
                  let list = data["fileList"] as? [[String: Any]],
                  let lastValue = data["lastFileId"] else {
                throw CloudDriveError.invalidResponse
            }
            for item in list {
                guard let name = item["filename"] as? String, let fid = item["fileId"] else {
                    throw CloudDriveError.invalidResponse
                }
                if (Self.intValue(item["trashed"]) ?? 0) != 0 { continue }   // 跳过回收站文件
                let isDir = Self.intValue(item["type"]) == 1
                let size = (item["size"] as? Int64) ?? Int64(Self.intValue(item["size"]) ?? 0)
                let etag = item["etag"] as? String
                let fileID = Self.idString(fid)
                all.append(RemoteFileItem(
                    name: name,
                    path: fileID,
                    isDirectory: isDir,
                    size: isDir ? 0 : size,
                    modifiedDate: nil,
                    revision: etag,
                    providerID: fileID,
                    parentPath: parent
                ))
            }
            // 123 分页:data.lastFileId == -1 表示到底。
            let next = Self.idString(lastValue)
            if next == "-1" { break }
            guard CloudPaginationTokenPolicy.canAdvance(
                to: next,
                seenTokens: seenLastFileIDs
            ) else {
                throw CloudDriveError.invalidResponse
            }
            seenLastFileIDs.insert(next)
            lastFileId = next
        }
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        return try await helper.downloadToCache(request: URLRequest(url: url), for: path)
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
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    // MARK: - Sidecar 回写(单步上传)

    /// 把刮削的 sidecar(封面 `-cover.jpg` / 歌词 `.lrc`)上传回 123 云盘,放源歌曲同目录、
    /// 用源文件真实名命名(重扫时 findSameName* 能按同名读回 → 多设备共享)。
    /// `path` 由 SidecarWriteService 用 `song.filePath`(123 是 fileId)拼成,形如
    /// `"{fileId}-cover.jpg"` / `"{fileId}.lrc"`。反解 fileId → 查详情拿真实名 + 父目录 → 上传。
    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if path.hasSuffix(".lrc") { suffix = ".lrc" }
        else { throw CloudDriveError.invalidResponse }
        let fileID = String(path.dropLast(suffix.count))
        guard !fileID.isEmpty else { throw CloudDriveError.invalidResponse }

        // 1. 查源文件详情 → 真实文件名 + 父目录 id
        let detail = try await authedRequest("/api/v1/file/detail?fileID=\(fileID)")
        let d = detail["data"] as? [String: Any] ?? [:]
        guard let srcName = d["filename"] as? String,
              let parentID = Self.intValue(d["parentFileID"]) else {
            throw CloudDriveError.invalidResponse
        }
        let sidecarName = (srcName as NSString).deletingPathExtension + suffix

        // 2. 单步上传(multipart 一次完成),duplicate=2 覆盖原 sidecar
        let domain = try await uploadDomain()
        do {
            try await singleStepUpload(domain: domain, parentFileID: parentID, filename: sidecarName, data: data)
        } catch {
            // Upload hosts are assigned dynamically and may be retired before
            // this actor is recreated. Refresh once; duplicate=2 makes retrying
            // the same sidecar idempotent if the first response was lost.
            cachedUploadDomain = nil
            let refreshedDomain = try await uploadDomain()
            try await singleStepUpload(
                domain: refreshedDomain,
                parentFileID: parentID,
                filename: sidecarName,
                data: data
            )
        }
        invalidateDownloadURL(for: fileID)
        plog("📁 123 sidecar uploaded: \(sidecarName)")
    }

    func deleteFile(at path: String) async throws {
        try await deleteFiles(at: [path])
    }

    func deleteFiles(at paths: [String]) async throws {
        let uniquePaths = Array(Set(paths))
        let ids = uniquePaths.compactMap(Self.intValue).sorted()
        guard !ids.isEmpty, ids.count == uniquePaths.count else {
            throw CloudDriveError.invalidResponse
        }
        let body = try SafeJSONSerialization.data(withJSONObject: ["fileIDs": ids])
        _ = try await authedRequest("/api/v1/file/trash", method: "POST", body: body)
        for path in uniquePaths { invalidateDownloadURL(for: path) }
        plog("🗑️ 123 Drive items moved to trash: \(ids.count)")
    }

    // MARK: - 上传辅助

    /// 获取上传域名(GET /upload/v2/file/domain → data:[域名]),短期缓存并在失败时刷新。
    private func uploadDomain() async throws -> String {
        if let cachedUploadDomain, cachedUploadDomain.expiresAt > Date() {
            return cachedUploadDomain.value
        }
        let json = try await authedRequest("/upload/v2/file/domain")
        let arr = json["data"] as? [String] ?? []
        let domain = (arr.first ?? Self.fallbackUploadDomain)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: domain),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw CloudDriveError.invalidResponse
        }
        cachedUploadDomain = (domain, Date().addingTimeInterval(Self.uploadDomainTTL))
        return domain
    }

    /// V2 单步上传:POST {上传域名}/upload/v2/file/single/create(multipart/form-data)。
    /// 适合 ≤1GB 小文件(封面/歌词),一次 HTTP 完成。etag 为文件 MD5(小写 hex)。
    private func singleStepUpload(domain: String, parentFileID: Int, filename: String, data: Data) async throws {
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(domain)/upload/v2/file/single/create") else {
            throw CloudDriveError.invalidResponse
        }
        let token = try await getToken()
        try await helper.withTokenRetry(initialToken: token, refresh: refreshToken, isTokenRejection: Self.isAuthError) { @Sendable tok in
            let boundary = "----PrimuseBoundary\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("parentFileID", String(parentFileID))
            field("filename", filename)
            field("etag", md5)
            field("size", String(data.count))
            field("duplicate", "2")   // 同名覆盖,使重新刮削能更新封面/歌词
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let (respData, response) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
            let code = Self.intValue(json["code"]) ?? -1
            if code == 401 { throw CloudDriveError.tokenExpired }
            guard code == 0 else { throw CloudDriveError.apiError(code, json["message"] as? String ?? "") }
        }
    }

    // MARK: - 下载直链

    private func getDownloadURL(for fileId: String) async throws -> URL {
        if let cached = downloadURLCache[fileId], cached.expiresAt > Date() { return cached.url }
        let json = try await authedRequest("/api/v1/file/download_info?fileId=\(fileId)")
        let data = json["data"] as? [String: Any] ?? [:]
        guard let link = data["downloadUrl"] as? String, let url = URL(string: link) else {
            throw CloudDriveError.fileNotFound(fileId)
        }
        downloadURLCache[fileId] = (url, Date().addingTimeInterval(Self.downloadURLTTL))
        return url
    }

    private func invalidateDownloadURL(for fileId: String) {
        downloadURLCache.removeValue(forKey: fileId)
    }

    // MARK: - 鉴权请求(Platform 头 + code==0 校验 + 401 刷新重试)

    /// 发一个带 `Platform: open_platform` + `Authorization` 的请求,校验 body `code==0`,
    /// 失败抛 `CloudDriveError.apiError`。HTTP 401 或 body code 401 → withTokenRetry
    /// 强制刷新 token 重试一次。返回顶层 JSON(调用方读 `["data"]`)。
    @discardableResult
    private func authedRequest(_ pathAndQuery: String, method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        let token = try await getToken()
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken, isTokenRejection: Self.isAuthError) { @Sendable tok in
            var req = URLRequest(url: URL(string: Self.apiBase + pathAndQuery)!)
            req.httpMethod = method
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            req.timeoutInterval = 60
            let mayRetry = method.uppercased() == "GET"
            var transientAttempt = 0
            var delay: TimeInterval = 0.75
            while true {
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await URLSession.shared.data(for: req)
                } catch {
                    let nsError = error as NSError
                    guard mayRetry,
                          nsError.domain == NSURLErrorDomain,
                          CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: nsError.code),
                          transientAttempt < 4 else { throw error }
                    transientAttempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 8)
                    continue
                }
                guard let http = response as? HTTPURLResponse else {
                    throw CloudDriveError.invalidResponse
                }
                if mayRetry,
                   CloudHTTPRetryPolicy.shouldRetry(statusCode: http.statusCode),
                   transientAttempt < 4 {
                    transientAttempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 8)
                    continue
                }
                if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
                if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
                if http.statusCode == 404 { throw CloudDriveError.fileNotFound(pathAndQuery) }
                if http.statusCode == 429 { throw CloudDriveError.rateLimited }
                guard (200...299).contains(http.statusCode) else {
                    throw CloudDriveError.apiError(
                        http.statusCode,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let code = Self.intValue(json["code"]) else {
                    throw CloudDriveError.invalidResponse
                }
                if code == 401 { throw CloudDriveError.tokenExpired }
                if code == 429 { throw CloudDriveError.rateLimited }
                guard code == 0 else {
                    throw CloudDriveError.apiError(code, json["message"] as? String ?? "")
                }
                return json
            }
        }
    }

    // MARK: - Token

    private func getToken() async throws -> String {
        // proactive:本地标记过期才刷新,与 reactive(401)共享 CloudTokenManager 的去重刷新,
        // 避免单次有效的 refresh_token 被并发刷新作废。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    /// 用 refresh_token 换新 access_token。123 的 oauth2/access_token 用 QueryString 传参,
    /// 且 refresh_token 单次有效 —— 必须保存返回的新 refresh_token(refreshDeduped 会落库)。
    /// nonisolated:只用 helper(Sendable)/静态常量/URLSession,不碰 actor 可变状态。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = try await helper.tokenManager.requireAppCredentials()
        guard !creds.clientId.isEmpty else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var comps = URLComponents(string: Self.tokenURL)!
        comps.queryItems = [
            .init(name: "client_id", value: creds.clientId),
            .init(name: "client_secret", value: creds.clientSecret ?? ""),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: rt),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("open_platform", forHTTPHeaderField: "Platform")
        let (data, response) = try await URLSession.shared.data(for: req)
        let envelope = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        var json = envelope
        if let inner = envelope["data"] as? [String: Any] { json = inner }   // 兼容 {code,data:{…}} 包裹
        guard let at = json["access_token"] as? String else {
            let code = envelope["code"] as? Int
            throw CloudDriveHelper.tokenRefreshFailure(
                statusCode: code == 0 ? (response as? HTTPURLResponse)?.statusCode : code,
                providerErrorCode: envelope["error"] as? String
            )
        }
        let expiresIn = (json["expires_in"] as? TimeInterval) ?? 30 * 24 * 3600
        return .init(accessToken: at,
                     refreshToken: json["refresh_token"] as? String ?? rt,
                     expiresAt: Date().addingTimeInterval(expiresIn))
    }

    /// 第三方挂载应用 OAuth(authorization_code)。123 授权服务器直接回调已登记的
    /// `primuse://oauth/123pan/callback`;scope 固定且逗号分隔;无 PKCE。
    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: authURL,
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: ["user:base", "file:all:read", "file:all:write"],
            redirectURI: redirectURI,
            scopeSeparator: ",",
            usesPKCE: false
        )
    }

    // MARK: - 小工具

    /// 123 的鉴权类错误:HTTP 401(tokenExpired)或 body code 401。
    private static func isAuthError(_ error: Error) -> Bool {
        if case CloudDriveError.tokenExpired = error { return true }
        if case CloudDriveError.apiError(401, _) = error { return true }
        return false
    }

    /// JSON 数字可能被 JSONSerialization 解析为 Int / NSNumber / String,统一取 Int。
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func idString(_ v: Any) -> String {
        if let i = v as? Int { return String(i) }
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return String(describing: v)
    }
}
