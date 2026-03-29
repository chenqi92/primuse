import Foundation
import PrimuseKit

/// 阿里云盘 Source — PDS API
actor AliyunDriveSource: MusicSourceConnector {
    let sourceID: String
    private let helper: CloudDriveHelper
    private var driveId: String?
    private static let apiBase = "https://openapi.alipan.com"
    private static let oauthBase = "https://openapi.alipan.com/oauth"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        _ = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] { driveId = id }
            else { driveId = try await fetchDriveId() }
        }
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let parentFileId = path.isEmpty || path == "/" ? "root" : path
        let body: [String: Any] = ["drive_id": driveId, "parent_file_id": parentFileId, "limit": 200, "order_by": "name", "order_direction": "ASC"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/list")!, method: "POST", body: bodyData, contentType: "application/json", accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, let fileId = item["file_id"] as? String, let type = item["type"] as? String else { return nil }
            return RemoteFileItem(name: name, path: fileId, isDirectory: type == "folder", size: item["size"] as? Int64 ?? 0, modifiedDate: nil)
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

    private func downloadFile(at path: String) async throws -> Data {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let token = try await getToken()
        let body: [String: Any] = ["drive_id": driveId, "file_id": path]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/getDownloadUrl")!, method: "POST", body: bodyData, contentType: "application/json", accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["url"] as? String, let fileURL = URL(string: downloadUrl) else { throw CloudDriveError.fileNotFound(path) }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: fileURL)
        return fileData
    }

    private func fetchDriveId() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/user/getDriveInfo")!, method: "POST", body: Data("{}".utf8), contentType: "application/json", accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Failed to get drive info") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let id = json["resource_drive_id"] as? String, !id.isEmpty { return id }
        guard let id = json["default_drive_id"] as? String else { throw CloudDriveError.invalidResponse }
        return id
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
        let body: [String: String] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": cid, "client_secret": creds?.clientSecret ?? ""]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "\(Self.oauthBase)/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 7200), extra: tokens.extra)
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(authURL: "\(oauthBase)/authorize", tokenURL: "\(oauthBase)/access_token", clientId: clientId, clientSecret: clientSecret, scopes: ["user:base", "file:all:read"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://aliyun/callback")
    }
}
