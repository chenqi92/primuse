import Foundation
import PrimuseKit

/// Google Drive Source — Drive API v3
actor GoogleDriveSource: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://www.googleapis.com/drive/v3"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let reversedClientIdKey = "PrimuseGoogleReversedClientID"

    private static func parseISO8601(_ s: String) -> Date? {
        // Drive's modifiedTime is RFC 3339 with fractional seconds.
        // Constructed per-call instead of cached because
        // ISO8601DateFormatter isn't Sendable under strict concurrency.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    /// Google's OIDC userinfo endpoint. `sub` is the OIDC subject —
    /// the canonical, immutable per-user identifier that Google
    /// guarantees stable across the lifetime of the account. Cheaper
    /// and more correct than reading `id` from `/oauth2/v1/userinfo`,
    /// which is the legacy Plus-style endpoint.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
        let (data, http) = try await helper.makeAuthorizedRequest(url: url, accessToken: token)
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let sub = json["sub"] as? String, !sub.isEmpty else {
            plog("⚠️ Google accountIdentifier: missing sub in response: \(json)")
            throw CloudDriveError.invalidResponse
        }
        return sub
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parentId = path.isEmpty || path == "/" ? "root" : path
        var all: [RemoteFileItem] = []
        var pageToken: String? = nil
        repeat {
            let token = try await getToken()
            var components = URLComponents(string: "\(Self.apiBase)/files")!
            var items: [URLQueryItem] = [
                .init(name: "q", value: "'\(parentId)' in parents and trashed = false"),
                // md5Checksum / headRevisionId fingerprint a file even
                // when it's overwritten through the same id with the
                // same size — Drive keeps the id stable across version
                // uploads, and modifiedTime alone isn't enough when the
                // overwrite happens in the same second.
                .init(name: "fields", value: "files(id,name,mimeType,size,modifiedTime,md5Checksum,headRevisionId),nextPageToken"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "orderBy", value: "name"),
            ]
            if let p = pageToken { items.append(.init(name: "pageToken", value: p)) }
            components.queryItems = items
            let (data, http) = try await helper.makeAuthorizedRequest(url: components.url!, accessToken: token)
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let files = json["files"] as? [[String: Any]] ?? []
            all.append(contentsOf: files.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let isDir = (item["mimeType"] as? String) == "application/vnd.google-apps.folder"
                let mtime = (item["modifiedTime"] as? String).flatMap(Self.parseISO8601)
                // Prefer md5Checksum (binary content fingerprint, doesn't
                // change unless bytes change). headRevisionId is a final
                // fallback — it changes per upload even when the file is
                // re-uploaded byte-identical, but that's still strictly
                // better than nil for catching overwrites.
                let revision = (item["md5Checksum"] as? String) ?? (item["headRevisionId"] as? String)
                return RemoteFileItem(name: name, path: id, isDirectory: isDir, size: Int64(item["size"] as? String ?? "0") ?? 0, modifiedDate: mtime, revision: revision)
            })
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return all
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

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(path)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        return try await helper.rangeRequest(url: components.url!, offset: offset, length: length, accessToken: token)
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
