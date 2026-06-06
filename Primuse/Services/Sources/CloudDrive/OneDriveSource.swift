import Foundation
import PrimuseKit

/// OneDrive Source — Microsoft Graph API
actor OneDriveSource: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let graphBase = "https://graph.microsoft.com/v1.0"
    private static let authBase = "https://login.microsoftonline.com/common/oauth2/v2.0"
    private static let fallbackRedirectURI = "\(CloudOAuthConfig.callbackScheme)://onedrive/callback"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }

    /// Microsoft Graph `/me` returns the signed-in user record. The `id`
    /// field is the Azure AD object identifier — stable across token
    /// refresh and across devices logged into the same Microsoft account.
    /// `$select=id` keeps the response tiny.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: URL(string: "\(Self.graphBase)/me?$select=id")!,
            accessToken: token
        )
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String, !id.isEmpty else {
            plog("⚠️ OneDrive accountIdentifier: missing id in response: \(json)")
            throw CloudDriveError.invalidResponse
        }
        return id
    }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let endpoint = (path.isEmpty || path == "/") ? "\(Self.graphBase)/me/drive/root/children" : "\(Self.graphBase)/me/drive/items/\(path)/children"
        var all: [RemoteFileItem] = []
        var nextURL: URL? = {
            var components = URLComponents(string: endpoint)!
            components.queryItems = [
                .init(name: "$select", value: "id,name,folder,file,size"),
                .init(name: "$top", value: "999"),
                .init(name: "$orderby", value: "name"),
            ]
            return components.url
        }()
        while let url = nextURL {
            let token = try await getToken()
            let (data, http) = try await helper.makeAuthorizedRequest(url: url, accessToken: token)
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let items = json["value"] as? [[String: Any]] ?? []
            all.append(contentsOf: items.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                // Microsoft Graph driveItem returns file.hashes.sha1Hash /
                // sha256Hash / quickXorHash. Use whichever is present as
                // the revision fingerprint; eTag is a final fallback.
                let revision: String? = {
                    if let file = item["file"] as? [String: Any],
                       let hashes = file["hashes"] as? [String: Any] {
                        if let h = hashes["sha256Hash"] as? String { return h }
                        if let h = hashes["sha1Hash"] as? String { return h }
                        if let h = hashes["quickXorHash"] as? String { return h }
                    }
                    return item["eTag"] as? String
                }()
                return RemoteFileItem(name: name, path: id, isDirectory: item["folder"] != nil, size: item["size"] as? Int64 ?? 0, modifiedDate: nil, revision: revision)
            })
            // @odata.nextLink 是完整 URL（已包含 skiptoken）
            if let next = json["@odata.nextLink"] as? String, let nextU = URL(string: next) {
                nextURL = nextU
            } else {
                nextURL = nil
            }
        }
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!, accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Item not found") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["@microsoft.graph.downloadUrl"] as? String, let fileURL = URL(string: downloadUrl) else { throw CloudDriveError.fileNotFound(path) }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: fileURL)
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

    /// Microsoft 推荐第三方流量带「装饰」User-Agent(格式 NONISV|公司|应用/版本),
    /// 否则 undecorated 流量在 SharePoint/OneDrive CDN 可能被降级调度。URLSession
    /// 跨 302 保留自定义 header, 所以重定向到 *.microsoftpersonalcontent.com CDN 后仍生效。
    private static let rangeUserAgent = "NONISV|Welape|Primuse/1.6.0"

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        // OneDrive returns a short-lived pre-authenticated downloadUrl per
        // item. Range requests against that URL don't need our Bearer token.
        // Cache it for ~50min (Microsoft documents 1h validity, leave margin).
        let fileURL = try await getDownloadURL(for: path)
        do {
            return try await helper.rangeRequest(url: fileURL, offset: offset, length: length, userAgent: Self.rangeUserAgent, forceTCP: true)
        } catch CloudDriveError.apiError(let code, _) where code == 401 || code == 403 || code == 410 {
            // URL expired between cache and use — invalidate and retry once.
            invalidateDownloadURL(for: path)
            let fresh = try await getDownloadURL(for: path)
            return try await helper.rangeRequest(url: fresh, offset: offset, length: length, userAgent: Self.rangeUserAgent, forceTCP: true)
        }
    }

    /// 暴露预授权下载直链,供大文件「整文件渐进下载」绕开逐 chunk Range。
    /// OneDrive 服务端对大文件的分段 Range 会挂死(冷文件 hydration),但整文件直接
    /// 下载很快 —— 大文件改走 StreamingDownloadDecoder 一次性渐进下载。
    func publicDownloadURL(path: String) async throws -> URL {
        try await getDownloadURL(for: path)
    }

    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    /// Microsoft documents `@microsoft.graph.downloadUrl` as valid for ~1
    /// hour. Use 50min to leave a safety margin against clock skew.
    private static let downloadURLTTL: TimeInterval = 50 * 60

    private func getDownloadURL(for path: String) async throws -> URL {
        if let cached = downloadURLCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!, accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Item not found") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["@microsoft.graph.downloadUrl"] as? String,
              let fileURL = URL(string: downloadUrl) else {
            throw CloudDriveError.fileNotFound(path)
        }
        downloadURLCache[path] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
        return fileURL
    }

    private func invalidateDownloadURL(for path: String) {
        downloadURLCache.removeValue(forKey: path)
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
        var request = URLRequest(url: URL(string: "\(Self.authBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudDriveHelper.formURLEncodedBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "scope", value: "Files.Read offline_access"),
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "\(authBase)/authorize",
            tokenURL: "\(authBase)/token",
            clientId: clientId,
            clientSecret: nil,
            scopes: ["Files.Read", "offline_access"],
            redirectURI: redirectURI()
        )
    }

    private static func redirectURI() -> String {
        guard let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return fallbackRedirectURI
        }
        return "msauth.\(bundleID)://auth"
    }
}
