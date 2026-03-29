import Foundation
import PrimuseKit

/// OneDrive Source — Microsoft Graph API
actor OneDriveSource: MusicSourceConnector {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let graphBase = "https://graph.microsoft.com/v1.0"
    private static let authBase = "https://login.microsoftonline.com/common/oauth2/v2.0"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let endpoint = (path.isEmpty || path == "/") ? "\(Self.graphBase)/me/drive/root/children" : "\(Self.graphBase)/me/drive/items/\(path)/children"
        let token = try await getToken()
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            .init(name: "$select", value: "id,name,folder,file,size"),
            .init(name: "$top", value: "999"),
            .init(name: "$orderby", value: "name"),
        ]
        let (data, http) = try await helper.makeAuthorizedRequest(url: components.url!, accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let items = json["value"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return RemoteFileItem(name: name, path: id, isDirectory: item["folder"] != nil, size: item["size"] as? Int64 ?? 0, modifiedDate: nil)
        }
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
        request.httpBody = "grant_type=refresh_token&refresh_token=\(rt)&client_id=\(cid)&scope=Files.Read.All offline_access".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(authURL: "\(authBase)/authorize", tokenURL: "\(authBase)/token", clientId: clientId, clientSecret: nil, scopes: ["Files.Read.All", "offline_access"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://onedrive/callback")
    }
}
