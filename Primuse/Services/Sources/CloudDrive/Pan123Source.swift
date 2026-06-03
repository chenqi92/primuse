import Foundation
import PrimuseKit

/// 123 云盘 Source — 123 开放平台 OpenAPI(open-api.123pan.com)。
///
/// 与其它云盘不同:123 开放平台用「client-credentials」——开发者(或用户)在
/// 123pan 开放平台申请到 clientID / clientSecret,直接换取 access_token(有效约
/// 30 天),没有浏览器重定向授权。所以这里的 access_token 由 clientID+secret
/// 直接获取并缓存;凭据存在 CloudTokenManager 的 AppCredentials 里。
///
/// 所有 API 请求需带头 `Platform: open_platform` + `Authorization: Bearer <token>`。
///
/// ⚠️ 占位:字段名/返回结构按 123 开放平台公开资料填写,拿到正式凭据后对照官方
/// 文档(https://www.123pan.cn/developer)联调。注意:列目录免费,下载直链
/// (download_info)可能需要开放平台付费权限。
actor Pan123Source: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper

    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 20 * 60
    private static let apiBase = "https://open-api.123pan.com"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        _ = try await getToken()
    }

    func disconnect() async {}

    /// 用 clientID 作为账户标识(同一开放平台应用即同一账户)。
    func accountIdentifier() async throws -> String {
        guard let creds = await helper.tokenManager.getAppCredentials(), !creds.clientId.isEmpty else {
            throw CloudDriveError.notAuthenticated
        }
        return creds.clientId
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parent = path.isEmpty || path == "/" ? "0" : path
        var all: [RemoteFileItem] = []
        var lastFileId: String? = nil
        while true {
            var comps = URLComponents(string: "\(Self.apiBase)/api/v2/file/list")!
            comps.queryItems = [
                URLQueryItem(name: "parentFileId", value: parent),
                URLQueryItem(name: "limit", value: "100"),
            ]
            if let l = lastFileId { comps.queryItems?.append(URLQueryItem(name: "lastFileId", value: l)) }
            let json = try await authorizedRequest(comps.url!)
            let data = json["data"] as? [String: Any] ?? [:]
            let list = data["fileList"] as? [[String: Any]] ?? []
            for item in list {
                guard let name = item["filename"] as? String, let fid = item["fileId"] else { continue }
                let isDir = (item["type"] as? Int == 1) || (item["type"] as? String == "1")
                let size = (item["size"] as? Int64) ?? Int64(item["size"] as? String ?? "0") ?? 0
                let etag = item["etag"] as? String
                all.append(RemoteFileItem(name: name, path: String(describing: fid),
                                          isDirectory: isDir, size: isDir ? 0 : size,
                                          modifiedDate: nil, revision: etag))
            }
            // 123 分页:data.lastFileId == -1 表示到底。
            let next = (data["lastFileId"] as? Int) ?? Int(String(describing: data["lastFileId"] ?? -1)) ?? -1
            if next == -1 { break }
            lastFileId = String(next)
        }
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: url)
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
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    // MARK: - 私有

    private func getDownloadURL(for fileId: String) async throws -> URL {
        if let cached = downloadURLCache[fileId], cached.expiresAt > Date() { return cached.url }
        var comps = URLComponents(string: "\(Self.apiBase)/api/v1/file/download_info")!
        comps.queryItems = [URLQueryItem(name: "fileId", value: fileId)]
        let json = try await authorizedRequest(comps.url!)
        let data = json["data"] as? [String: Any] ?? [:]
        guard let link = data["downloadUrl"] as? String, let url = URL(string: link) else {
            throw CloudDriveError.fileNotFound(fileId)
        }
        downloadURLCache[fileId] = (url, Date().addingTimeInterval(Self.downloadURLTTL))
        return url
    }

    /// 带 Platform 头的鉴权请求;校验 code == 0。
    private func authorizedRequest(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        let token = try await getToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("open_platform", forHTTPHeaderField: "Platform")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await URLSession.shared.data(for: req)
        let code = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudDriveError.apiError(code, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (json["code"] as? Int) == 0 else {
            throw CloudDriveError.apiError((json["code"] as? Int) ?? -1, json["message"] as? String ?? "")
        }
        return json
    }

    /// client-credentials 换 token,缓存到过期。
    private func getToken() async throws -> String {
        if let t = await helper.tokenManager.getTokens(), !t.isExpired, !t.accessToken.isEmpty {
            return t.accessToken
        }
        guard let creds = await helper.tokenManager.getAppCredentials(),
              let secret = creds.clientSecret,
              !creds.clientId.isEmpty, !secret.isEmpty else {
            throw CloudDriveError.notAuthenticated
        }
        let tokens = try await fetchAccessToken(clientID: creds.clientId, clientSecret: secret)
        await helper.tokenManager.saveTokens(tokens)
        return tokens.accessToken
    }

    private func fetchAccessToken(clientID: String, clientSecret: String) async throws -> CloudTokenManager.Tokens {
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("open_platform", forHTTPHeaderField: "Platform")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["clientID": clientID, "clientSecret": clientSecret])
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (json["code"] as? Int) == 0,
              let payload = json["data"] as? [String: Any],
              let at = payload["accessToken"] as? String else {
            throw CloudDriveError.tokenRefreshFailed(json["message"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }
        let expiresAt = Self.parseExpiry(payload["expiredAt"]) ?? Date().addingTimeInterval(25 * 24 * 3600)
        return .init(accessToken: at, refreshToken: nil, expiresAt: expiresAt, extra: nil)
    }

    private static func parseExpiry(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: s)
    }

    /// ⚠️ 占位:123 用 client-credentials(无重定向),不走标准 OAuth 授权页。
    /// 添加源时让用户填 clientID(username)+ clientSecret,连接器直接换 token。
    /// 这里给空配置只为让通用云盘 switch 编译通过。
    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "",
            tokenURL: "\(apiBase)/api/v1/access_token",
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: [],
            redirectURI: "\(CloudOAuthConfig.callbackScheme)://pan123/callback",
            usesPKCE: false
        )
    }
}
