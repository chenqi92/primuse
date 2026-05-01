import Foundation
import PrimuseKit

/// OneDrive Source — Microsoft Graph API
actor OneDriveSource: MusicSourceConnector {
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
                return RemoteFileItem(name: name, path: id, isDirectory: item["folder"] != nil, size: item["size"] as? Int64 ?? 0, modifiedDate: nil)
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

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        // OneDrive returns a short-lived pre-authenticated downloadUrl per item.
        // Range requests against that URL don't need our Bearer token.
        let token = try await getToken()
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!, accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Item not found") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["@microsoft.graph.downloadUrl"] as? String,
              let fileURL = URL(string: downloadUrl) else {
            throw CloudDriveError.fileNotFound(path)
        }
        return try await helper.rangeRequest(url: fileURL, offset: offset, length: length)
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
        request.httpBody = "grant_type=refresh_token&refresh_token=\(rt)&client_id=\(cid)&scope=Files.Read offline_access".data(using: .utf8)
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
