import Foundation
import PrimuseKit

/// Dropbox Source — API v2
actor DropboxSource: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper
    private static let apiBase = "https://api.dropboxapi.com/2"
    private static let contentBase = "https://content.dropboxapi.com/2"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    /// `users/get_current_account` returns the Dropbox account record.
    /// `account_id` is the stable per-user identifier (format `dbid:...`).
    /// Note: Dropbox treats this as an RPC call requiring a `null` JSON
    /// body and `Content-Type: application/json`.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let nullBody = Data("null".utf8)
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: URL(string: "\(Self.apiBase)/users/get_current_account")!,
            method: "POST",
            body: nullBody,
            contentType: "application/json",
            accessToken: token
        )
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = json["account_id"] as? String, !id.isEmpty else {
            plog("⚠️ Dropbox accountIdentifier: missing account_id in response: \(json)")
            throw CloudDriveError.invalidResponse
        }
        return id
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let folderPath = (path.isEmpty || path == "/") ? "" : path
        var all: [RemoteFileItem] = []

        // 首次：files/list_folder
        var json = try await postJSON(
            url: "\(Self.apiBase)/files/list_folder",
            body: ["path": folderPath, "limit": 2000, "include_mounted_folders": true]
        )
        all.append(contentsOf: parseEntries(json))

        // 翻页：files/list_folder/continue 直到 has_more == false
        while (json["has_more"] as? Bool) == true, let cursor = json["cursor"] as? String {
            json = try await postJSON(
                url: "\(Self.apiBase)/files/list_folder/continue",
                body: ["cursor": cursor]
            )
            all.append(contentsOf: parseEntries(json))
        }
        return all
    }

    private func postJSON(url: String, body: [String: Any]) async throws -> [String: Any] {
        let token = try await getToken()
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await helper.makeAuthorizedRequest(url: URL(string: url)!, method: "POST", body: bodyData, contentType: "application/json", accessToken: token)
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func parseEntries(_ json: [String: Any]) -> [RemoteFileItem] {
        guard let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String, let pathDisplay = entry["path_display"] as? String, let tag = entry[".tag"] as? String else { return nil }
            // Dropbox returns `content_hash` (their custom 4MB-block hash)
            // for files. `rev` is also stable per file version. Either
            // works as the revision fingerprint.
            let revision = entry["content_hash"] as? String ?? entry["rev"] as? String
            return RemoteFileItem(name: name, path: pathDisplay, isDirectory: tag == "folder", size: entry["size"] as? Int64 ?? 0, modifiedDate: nil, revision: revision)
        }
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        var request = URLRequest(url: URL(string: "\(Self.contentBase)/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("{\"path\":\"\(path)\"}", forHTTPHeaderField: "Dropbox-API-Arg")
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, "Download failed")
        }
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
        // Use Dropbox's `get_temporary_link` to obtain a short-lived
        // pre-signed URL (4-hour validity per Dropbox docs; we cache 50 min
        // for safety). Range requests against the link don't need our
        // Bearer token + Dropbox-API-Arg per call — saves one POST round
        // trip per chunk and avoids hammering the API endpoint, which is
        // what alist's official driver does.
        let url = try await getTemporaryLink(for: path)
        do {
            return try await helper.rangeRequest(url: url, offset: offset, length: length)
        } catch CloudDriveError.apiError(let code, _) where code == 401 || code == 403 || code == 410 {
            invalidateTemporaryLink(for: path)
            let fresh = try await getTemporaryLink(for: path)
            return try await helper.rangeRequest(url: fresh, offset: offset, length: length)
        }
    }

    private var temporaryLinkCache: [String: (url: URL, expiresAt: Date)] = [:]
    /// Dropbox's temp links are valid for 4 hours; cache 50 min for
    /// margin. Renews per-path on demand.
    private static let temporaryLinkTTL: TimeInterval = 50 * 60

    private func getTemporaryLink(for path: String) async throws -> URL {
        if let cached = temporaryLinkCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        let token = try await getToken()
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: URL(string: "\(Self.apiBase)/files/get_temporary_link")!,
            method: "POST",
            body: body,
            contentType: "application/json",
            accessToken: token
        )
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let link = json["link"] as? String, let url = URL(string: link) else {
            throw CloudDriveError.fileNotFound(path)
        }
        temporaryLinkCache[path] = (url, Date().addingTimeInterval(Self.temporaryLinkTTL))
        return url
    }

    private func invalidateTemporaryLink(for path: String) {
        temporaryLinkCache.removeValue(forKey: path)
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
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = "grant_type=refresh_token&refresh_token=\(rt)&client_id=\(cid)"
        if let secret = creds?.clientSecret { body += "&client_secret=\(secret)" }
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let at = json["access_token"] as? String else { throw CloudDriveError.tokenRefreshFailed("") }
        return .init(accessToken: at, refreshToken: rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 14400))
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(authURL: "https://www.dropbox.com/oauth2/authorize", tokenURL: "https://api.dropboxapi.com/oauth2/token", clientId: clientId, clientSecret: clientSecret, scopes: ["files.content.read", "files.metadata.read"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://dropbox/callback")
    }
}
