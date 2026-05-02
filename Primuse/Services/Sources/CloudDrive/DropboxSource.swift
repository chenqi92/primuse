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
        let token = try await getToken()
        var request = URLRequest(url: URL(string: "\(Self.contentBase)/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Escape path for JSON header value
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        request.setValue("{\"path\":\"\(escaped)\"}", forHTTPHeaderField: "Dropbox-API-Arg")
        let rangeHeader: String
        if offset < 0 {
            rangeHeader = "bytes=\(offset)"
        } else {
            rangeHeader = "bytes=\(offset)-\(offset + length - 1)"
        }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.apiError(0, "Range fetch failed")
        }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            // Same correction as CloudDriveHelper.rangeRequest — Dropbox should
            // honor Range, but if some intermediary strips the header we'd
            // otherwise write the file head into a mid-file cache offset.
            let totalSize = Int64(data.count)
            let actualOffset: Int64 = offset < 0
                ? max(0, totalSize + offset)
                : offset
            guard actualOffset < totalSize else { return Data() }
            let upper = min(actualOffset + length, totalSize)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw CloudDriveError.apiError(http.statusCode, "Range fetch failed")
        }
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
