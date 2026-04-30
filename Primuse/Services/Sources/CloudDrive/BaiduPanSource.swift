import Foundation
import PrimuseKit

/// 百度网盘 Source — 使用百度开放平台 REST API
actor BaiduPanSource: MusicSourceConnector {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://pan.baidu.com"
    private static let oauthBase = "https://openapi.baidu.com/oauth/2.0"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let dir = path.isEmpty ? "/" : path
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/rest/2.0/xpan/file")!
        components.queryItems = [
            .init(name: "method", value: "list"),
            .init(name: "access_token", value: token),
            .init(name: "dir", value: dir),
            .init(name: "order", value: "name"),
            .init(name: "limit", value: "1000"),
        ]
        guard let url = components.url else { throw CloudDriveError.invalidResponse }

        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
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

    // MARK: - Private

    private func downloadFile(at path: String) async throws -> Data {
        let token = try await getToken()
        // Get fs_id
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var listComp = URLComponents(string: "\(Self.apiBase)/rest/2.0/xpan/file")!
        listComp.queryItems = [
            .init(name: "method", value: "list"),
            .init(name: "access_token", value: token),
            .init(name: "dir", value: dir),
        ]
        let (listData, _) = try await URLSession.shared.data(from: listComp.url!)
        let listJson = try JSONSerialization.jsonObject(with: listData) as? [String: Any] ?? [:]
        guard let entries = listJson["list"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["server_filename"] as? String) == name }),
              let fsId = entry["fs_id"] as? Int64 else {
            throw CloudDriveError.fileNotFound(path)
        }
        // Get dlink
        var metaComp = URLComponents(string: "\(Self.apiBase)/rest/2.0/xpan/multimedia")!
        metaComp.queryItems = [
            .init(name: "method", value: "filemetas"),
            .init(name: "access_token", value: token),
            .init(name: "fsids", value: "[\(fsId)]"),
            .init(name: "dlink", value: "1"),
        ]
        let (metaData, _) = try await URLSession.shared.data(from: metaComp.url!)
        let metaJson = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] ?? [:]
        guard let metas = metaJson["list"] as? [[String: Any]],
              let dlink = metas.first?["dlink"] as? String else {
            throw CloudDriveError.fileNotFound(path)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: URL(string: "\(dlink)&access_token=\(token)")!)
        return fileData
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
