import Foundation
import PrimuseKit

/// Dropbox Source — API v2
actor DropboxSource: MusicSourceConnector, OAuthCloudSource, IncrementalMusicSourceConnector {
    private enum DropboxAPIError: Error {
        case invalidCursor
    }
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削歌词/封面写回 Dropbox 同目录
    private let helper: CloudDriveHelper
    private static let apiBase = "https://api.dropboxapi.com/2"
    private static let contentBase = "https://content.dropboxapi.com/2"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    /// 写 sidecar(歌词/封面)到 Dropbox。Dropbox 的 filePath 就是真实路径,SidecarWriteService
    /// 直接拼好了同目录同名的 `to`(如 /music/x-cover.jpg、/music/x.lrc),覆盖上传即可。
    func writeFile(data: Data, to path: String) async throws {
        let token = try await getToken()
        // Dropbox-API-Arg 必须是 ASCII,中文等需转 \uXXXX。
        let arg = "{\"path\":\"\(Self.apiArgEscaped(path))\",\"mode\":\"overwrite\",\"mute\":true}"
        try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            var req = URLRequest(url: URL(string: "\(Self.contentBase)/files/upload")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue(arg, forHTTPHeaderField: "Dropbox-API-Arg")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
            guard let http = resp as? HTTPURLResponse else {
                throw CloudDriveError.invalidResponse
            }
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            guard (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(http.statusCode, "Dropbox sidecar upload failed")
            }
        }
        plog("📁 Dropbox sidecar uploaded: \((path as NSString).lastPathComponent)")
    }

    private static func apiArgEscaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if u.value < 0x20 || u.value > 0x7E { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    /// `users/get_current_account` returns the Dropbox account record.
    /// `account_id` is the stable per-user identifier (format `dbid:...`).
    /// Note: Dropbox treats this as an RPC call requiring a `null` JSON
    /// body and `Content-Type: application/json`.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let nullBody = Data("null".utf8)
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/users/get_current_account")!,
                method: "POST",
                body: nullBody,
                contentType: "application/json",
                accessToken: tok
            )
        }
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
            body: ["path": folderPath, "limit": 2000, "include_mounted_folders": true],
            isIdempotent: true
        )
        all.append(contentsOf: try parseEntries(json, parentPath: folderPath))

        // 翻页：files/list_folder/continue 直到 has_more == false
        var seenCursors: Set<String> = []
        while (json["has_more"] as? Bool) == true {
            guard let cursor = json["cursor"] as? String,
                  CloudPaginationTokenPolicy.canAdvance(
                    to: cursor,
                    seenTokens: seenCursors
                  ) else {
                throw CloudDriveError.invalidResponse
            }
            seenCursors.insert(cursor)
            json = try await postJSON(
                url: "\(Self.apiBase)/files/list_folder/continue",
                body: ["cursor": cursor],
                isIdempotent: true
            )
            all.append(contentsOf: try parseEntries(json, parentPath: folderPath))
        }
        return all
    }

    private func postJSON(
        url: String,
        body: [String: Any],
        isIdempotent: Bool = false
    ) async throws -> [String: Any] {
        let token = try await getToken()
        let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: url)!,
                method: "POST",
                body: bodyData,
                contentType: "application/json",
                accessToken: tok,
                isIdempotent: isIdempotent
            )
        }
        if http.statusCode == 409 {
            if Self.isPathNotFoundError(data) {
                throw CloudDriveError.fileNotFound(body["path"] as? String ?? "")
            }
            if Self.isInvalidCursorError(data) {
                throw DropboxAPIError.invalidCursor
            }
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudDriveError.invalidResponse
        }
        return json
    }

    private nonisolated static func isPathNotFoundError(_ data: Data) -> Bool {
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("path/not_found") || body.contains("path_lookup/not_found")
    }

    private nonisolated static func isInvalidCursorError(_ data: Data) -> Bool {
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("reset")
            || body.contains("invalid_cursor")
            || body.contains("invalid/cursor")
    }

    private func parseEntries(_ json: [String: Any], parentPath: String?) throws -> [RemoteFileItem] {
        guard let entries = json["entries"] as? [[String: Any]] else {
            throw CloudDriveError.invalidResponse
        }
        return try entries.map { entry in
            guard let name = entry["name"] as? String,
                  let pathDisplay = entry["path_display"] as? String,
                  let tag = entry[".tag"] as? String else {
                throw CloudDriveError.invalidResponse
            }
            // Dropbox returns `content_hash` (their custom 4MB-block hash)
            // for files. `rev` is also stable per file version. Either
            // works as the revision fingerprint.
            let revision = entry["content_hash"] as? String ?? entry["rev"] as? String
            let resolvedParent = (pathDisplay as NSString).deletingLastPathComponent
            return RemoteFileItem(
                name: name,
                path: pathDisplay,
                isDirectory: tag == "folder",
                size: entry["size"] as? Int64 ?? 0,
                modifiedDate: nil,
                revision: revision,
                providerID: entry["id"] as? String,
                parentPath: resolvedParent.isEmpty ? (parentPath ?? "") : resolvedParent
            )
        }
    }

    func initialChangeCursors(for roots: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        for root in roots {
            let path = root.isEmpty || root == "/" ? "" : root
            let json = try await postJSON(
                url: "\(Self.apiBase)/files/list_folder/get_latest_cursor",
                body: [
                    "path": path,
                    "recursive": true,
                    "include_deleted": true,
                    "include_mounted_folders": true,
                ],
                isIdempotent: true
            )
            guard let cursor = json["cursor"] as? String, !cursor.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            result[root] = cursor
        }
        return result
    }

    func changes(
        since cursors: [String: String],
        roots: [String],
        index: [String: SourceSyncIndexedItem]
    ) async throws -> IncrementalSourceChanges {
        var nextCursors = cursors
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var liveStableKeys: Set<String> = []
        var requiresDeep = false

        for root in roots {
            guard var cursor = cursors[root], !cursor.isEmpty else {
                return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
            }
            var seenCursors: Set<String> = []
            while true {
                guard CloudPaginationTokenPolicy.canAdvance(
                    to: cursor,
                    seenTokens: seenCursors
                ) else {
                    throw CloudDriveError.invalidResponse
                }
                seenCursors.insert(cursor)
                let json: [String: Any]
                do {
                    json = try await postJSON(
                        url: "\(Self.apiBase)/files/list_folder/continue",
                        body: ["cursor": cursor],
                        isIdempotent: true
                    )
                } catch DropboxAPIError.invalidCursor {
                    return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
                }
                guard let entries = json["entries"] as? [[String: Any]] else {
                    throw CloudDriveError.invalidResponse
                }
                for entry in entries {
                    let tag = entry[".tag"] as? String
                    let displayPath = (entry["path_display"] as? String)
                        ?? (entry["path_lower"] as? String)
                    if tag == "folder" {
                        requiresDeep = true
                        continue
                    }
                    if tag == "deleted" {
                        guard let displayPath else { requiresDeep = true; continue }
                        let match = index.first { _, value in
                            value.path.caseInsensitiveCompare(displayPath) == .orderedSame
                        }
                        if let match {
                            deletedKeys.insert(match.key)
                            if let parent = match.value.parentPath { changedParents.insert(parent) }
                        } else {
                            let parent = (displayPath as NSString).deletingLastPathComponent
                            changedParents.insert(parent)
                        }
                        continue
                    }
                    guard tag == "file", let displayPath else { continue }
                    if let providerID = entry["id"] as? String {
                        // A move can be represented as old-path deletion plus
                        // the same stable id at a new path in one cursor page.
                        deletedKeys.remove(providerID)
                        liveStableKeys.insert(providerID)
                    }
                    let parent = (displayPath as NSString).deletingLastPathComponent
                    changedParents.insert(parent)
                    if let providerID = entry["id"] as? String,
                       let old = index[providerID],
                       let oldParent = old.parentPath,
                       oldParent != parent {
                        changedParents.insert(oldParent)
                    }
                }
                guard let returnedCursor = json["cursor"] as? String,
                      !returnedCursor.isEmpty else {
                    throw CloudDriveError.invalidResponse
                }
                cursor = returnedCursor
                if json["has_more"] as? Bool != true { break }
            }
            nextCursors[root] = cursor
        }
        deletedKeys.subtract(liveStableKeys)
        return IncrementalSourceChanges(
            cursors: nextCursors,
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            requiresDeepScan: requiresDeep
        )
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        let argData = try SafeJSONSerialization.data(withJSONObject: ["path": path])
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            var request = URLRequest(url: URL(string: "\(Self.contentBase)/files/download")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            request.setValue(String(data: argData, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
            request.timeoutInterval = 300
            return try await self.helper.downloadToCache(request: request, for: path)
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    /// Remove the server-side entry with Dropbox delete_v2 and require the
    /// returned metadata as confirmation before Primuse removes its row.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty else { throw CloudDriveError.invalidResponse }
        let json = try await postJSON(
            url: "\(Self.apiBase)/files/delete_v2",
            body: ["path": path]
        )
        guard let metadata = json["metadata"] as? [String: Any],
              let tag = metadata[".tag"] as? String,
              tag == "file" || tag == "folder" else {
            throw CloudDriveError.apiError(200, "Dropbox did not confirm deleted metadata")
        }
        invalidateTemporaryLink(for: path)
        plog("🗑️ Dropbox item deleted: \(path)")
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
        let body = try SafeJSONSerialization.data(withJSONObject: ["path": path])
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/files/get_temporary_link")!,
                method: "POST",
                body: body,
                contentType: "application/json",
                accessToken: tok
            )
        }
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
        // proactive 路径: 本地标记过期才刷新, 与 reactive(401)路径共享 CloudTokenManager
        // 里的同一个 in-flight 去重任务, 避免轮换型 refresh_token 被并发刷新作废。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    // nonisolated: 只用 helper(Sendable)/静态常量/URLSession, 不碰可变 actor 状态,
    // 这样能作为 @Sendable 闭包传给 tokenManager.refreshDeduped / withTokenRetry。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = try await helper.tokenManager.requireAppCredentials()
        guard !creds.clientId.isEmpty else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
            URLQueryItem(name: "client_id", value: creds.clientId),
        ]
        if let secret = creds.clientSecret {
            items.append(URLQueryItem(name: "client_secret", value: secret))
        }
        request.httpBody = CloudDriveHelper.formURLEncodedBody(items)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        guard let at = json["access_token"] as? String else {
            throw CloudDriveHelper.tokenRefreshFailure(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return .init(accessToken: at, refreshToken: rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 14400))
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(authURL: "https://www.dropbox.com/oauth2/authorize", tokenURL: "https://api.dropboxapi.com/oauth2/token", clientId: clientId, clientSecret: clientSecret, scopes: ["account_info.read", "files.content.read", "files.content.write", "files.metadata.read", "files.metadata.write"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://dropbox/callback")
    }
}
