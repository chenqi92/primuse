import Foundation
import PrimuseKit

/// Google Drive Source — Drive API v3
actor GoogleDriveSource: MusicSourceConnector {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://www.googleapis.com/drive/v3"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let reversedClientIdKey = "PrimuseGoogleReversedClientID"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parentId = path.isEmpty || path == "/" ? "root" : path
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files")!
        components.queryItems = [
            .init(name: "q", value: "'\(parentId)' in parents and trashed = false"),
            .init(name: "fields", value: "files(id,name,mimeType,size,modifiedTime)"),
            .init(name: "pageSize", value: "1000"),
            .init(name: "orderBy", value: "name"),
        ]
        let (data, http) = try await helper.makeAuthorizedRequest(url: components.url!, accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let files = json["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let isDir = (item["mimeType"] as? String) == "application/vnd.google-apps.folder"
            return RemoteFileItem(name: name, path: id, isDirectory: isDir, size: Int64(item["size"] as? String ?? "0") ?? 0, modifiedDate: nil)
        }
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(path)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        let (data, http) = try await helper.makeAuthorizedRequest(url: components.url!, accessToken: token)
        guard (200...299).contains(http.statusCode) else { throw CloudDriveError.apiError(http.statusCode, "Download failed") }
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
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(rt)&client_id=\(cid)".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            authURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: nil,
            scopes: ["https://www.googleapis.com/auth/drive.readonly"],
            redirectURI: redirectURI()
        )
    }

    private static func redirectURI() -> String {
        if let scheme = Bundle.main.object(forInfoDictionaryKey: reversedClientIdKey) as? String {
            let trimmed = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed):/oauth2redirect"
            }
        }
        return "\(CloudOAuthConfig.callbackScheme)://google/callback"
    }
}
