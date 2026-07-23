import CryptoKit
import Foundation
import PrimuseKit

/// 阿里云盘 Source — PDS API
actor AliyunDriveSource: MusicSourceConnector, OAuthCloudSource, RemoteFileDisplayNameProviding {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削歌词/封面写回阿里云盘同目录
    private let helper: CloudDriveHelper
    private var driveId: String?

    /// 写 sidecar 到阿里云盘:openFile/get 查父目录 → create(sha1 content_hash + proof_code v1
    /// 尝试秒传) →(未秒传则 PUT 内容) → complete。filePath 是 file_id,`to` 形如
    /// "{fileID}-cover.jpg" / "{fileID}.lrc"。同名已存在则视为已完成(check_name_mode=refuse)。
    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if path.hasSuffix(".lrc") { suffix = ".lrc" }
        else { throw CloudDriveError.invalidResponse }
        let fileID = String(path.dropLast(suffix.count))
        guard !fileID.isEmpty else { throw CloudDriveError.invalidResponse }

        let token = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] { driveId = id }
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }

        // 整段写流程套 withTokenRetry:服务端提前失效 token(401)时一次性强制刷新 +
        // 重跑(get → create → 可选 PUT → complete),而不是等本地 expiresAt 过期。
        try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            // 1. 查源文件的父目录 + 真实文件名
            let getBody = try SafeJSONSerialization.data(withJSONObject: ["drive_id": driveId, "file_id": fileID])
            let (dData, dHTTP) = try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/get")!,
                method: "POST", body: getBody, contentType: "application/json", accessToken: tok)
            guard dHTTP.statusCode == 200 else { throw CloudDriveError.apiError(dHTTP.statusCode, "aliyun file get") }
            let dJSON = (try? JSONSerialization.jsonObject(with: dData)) as? [String: Any] ?? [:]
            guard let name = dJSON["name"] as? String,
                  let parentFileId = dJSON["parent_file_id"] as? String else { throw CloudDriveError.invalidResponse }
            let sidecarName = (name as NSString).deletingPathExtension + suffix

            let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
            // 2. create(带 proof_code 尝试秒传)
            let createBody = try SafeJSONSerialization.data(withJSONObject: [
                "drive_id": driveId, "parent_file_id": parentFileId, "name": sidecarName,
                "type": "file", "check_name_mode": "refuse", "size": data.count,
                "content_hash_name": "sha1", "content_hash": sha1,
                "proof_version": "v1", "proof_code": Self.proofCode(token: tok, data: data),
                "part_info_list": [["part_number": 1]],
            ])
            let (cData, cHTTP) = try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/create")!,
                method: "POST", body: createBody, contentType: "application/json", accessToken: tok)
            guard (200...201).contains(cHTTP.statusCode) else { throw CloudDriveError.apiError(cHTTP.statusCode, "aliyun create") }
            let cJSON = (try? JSONSerialization.jsonObject(with: cData)) as? [String: Any] ?? [:]
            if cJSON["exist"] as? Bool == true { return }   // 同名 sidecar 已在,视为完成
            let rapid = cJSON["rapid_upload"] as? Bool ?? false
            guard let newFileId = cJSON["file_id"] as? String,
                  let uploadId = cJSON["upload_id"] as? String else {
                // 秒传命中且无 upload_id 也算成功
                if rapid { plog("📁 Aliyun sidecar rapid-uploaded: \(sidecarName)"); return }
                throw CloudDriveError.apiError(0, "aliyun create no upload_id: \(cJSON)")
            }

            // 3. 未秒传则 PUT 内容到分片上传地址
            if !rapid, let uploadURL = (cJSON["part_info_list"] as? [[String: Any]])?.first?["upload_url"] as? String,
               let put = URL(string: uploadURL) {
                var putReq = URLRequest(url: put)
                putReq.httpMethod = "PUT"
                let (_, pResp) = try await URLSession.shared.upload(for: putReq, from: data)
                guard let ph = pResp as? HTTPURLResponse, (200...299).contains(ph.statusCode) else {
                    throw CloudDriveError.apiError((pResp as? HTTPURLResponse)?.statusCode ?? 0, "aliyun part PUT")
                }
            }

            // 4. complete
            let completeBody = try SafeJSONSerialization.data(withJSONObject: [
                "drive_id": driveId, "file_id": newFileId, "upload_id": uploadId,
            ])
            _ = try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/complete")!,
                method: "POST", body: completeBody, contentType: "application/json", accessToken: tok)
            plog("📁 Aliyun sidecar uploaded: \(sidecarName)")
        }
    }

    /// 阿里云盘秒传 proof_code v1:取 md5(access_token) 前 16 个 hex 当 UInt64,对文件大小取模
    /// 得起点,取该处 8 字节做 base64。
    private static func proofCode(token: String, data: Data) -> String {
        let md5hex = Insecure.MD5.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        guard data.count > 0, let num = UInt64(md5hex.prefix(16), radix: 16) else { return "" }
        let start = Int(num % UInt64(data.count))
        let end = min(start + 8, data.count)
        return data.subdata(in: start..<end).base64EncodedString()
    }
    /// path → (downloadURL, expiry). Aliyun signed URLs are good for ~4
    /// hours; we cache for 30min to skip the getDownloadUrl round-trip on
    /// every range fetch within a single play session.
    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 30 * 60
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

    /// Aliyun's OIDC `oauth/users/info` endpoint — returns the OAuth
    /// account UID independent of which drive the user picks. Stable
    /// across token refresh and across devices.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.oauthBase)/users/info")!,
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // Aliyun returns `id`; `sub` is provided when the response is
        // a true OIDC token. Accept either to ride out provider drift.
        if let id = json["id"] as? String, !id.isEmpty { return id }
        if let sub = json["sub"] as? String, !sub.isEmpty { return sub }
        plog("⚠️ Aliyun accountIdentifier: missing id/sub in response: \(json)")
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let parentFileId = path.isEmpty || path == "/" ? "root" : path
        var all: [RemoteFileItem] = []
        var marker: String? = nil
        repeat {
            var body: [String: Any] = ["drive_id": driveId, "parent_file_id": parentFileId, "limit": 200, "order_by": "name", "order_direction": "ASC"]
            if let m = marker, !m.isEmpty { body["marker"] = m }
            let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
            let token = try await getToken()
            let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/list")!, method: "POST", body: bodyData, contentType: "application/json", accessToken: tok)
            }
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let items = json["items"] as? [[String: Any]] ?? []
            all.append(contentsOf: items.compactMap { item in
                guard let name = item["name"] as? String, let fileId = item["file_id"] as? String, let type = item["type"] as? String else { return nil }
                // Aliyun returns content_hash (sha1 by default) for files;
                // use it as the revision so re-scan catches same-size,
                // same-mtime overwrites.
                let hash = item["content_hash"] as? String
                return RemoteFileItem(name: name, path: fileId, isDirectory: type == "folder", size: item["size"] as? Int64 ?? 0, modifiedDate: nil, revision: hash)
            })
            let next = json["next_marker"] as? String
            marker = (next?.isEmpty == false) ? next : nil
        } while marker != nil
        return all
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

    func displayName(for path: String) async throws -> String? {
        let token = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] {
                driveId = id
            } else {
                driveId = try await fetchDriveId()
            }
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let body = try SafeJSONSerialization.data(withJSONObject: ["drive_id": driveId, "file_id": path])
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/get")!,
                method: "POST",
                body: body,
                contentType: "application/json",
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, "Aliyun file name lookup")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["name"] as? String
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    /// Move the item to Aliyun Drive's recycle bin. PDS may report failures
    /// in a JSON body, so a 2xx status alone is not treated as confirmation.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty, let driveId else { throw CloudDriveError.invalidResponse }
        let token = try await getToken()
        let body = try SafeJSONSerialization.data(withJSONObject: [
            "drive_id": driveId,
            "file_id": path,
        ])
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/recyclebin/trash")!,
                method: "POST",
                body: body,
                contentType: "application/json",
                accessToken: tok
            )
        }
        guard (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["code"] as? String, !code.isEmpty {
            throw CloudDriveError.apiError(http.statusCode, "\(code): \(json["message"] as? String ?? "")")
        }
        downloadURLCache.removeValue(forKey: path)
        plog("🗑️ Aliyun Drive item moved to recycle bin: \(path)")
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    private func downloadFile(at path: String) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (fileData, _) = try await URLSession(configuration: config).data(from: url)
        return fileData
    }

    private func getDownloadURL(for path: String) async throws -> URL {
        if let cached = downloadURLCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let token = try await getToken()
        let body: [String: Any] = ["drive_id": driveId, "file_id": path]
        let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/getDownloadUrl")!, method: "POST", body: bodyData, contentType: "application/json", accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["url"] as? String, let fileURL = URL(string: downloadUrl) else {
            throw CloudDriveError.fileNotFound(path)
        }
        downloadURLCache[path] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
        return fileURL
    }

    private func fetchDriveId() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/user/getDriveInfo")!, method: "POST", body: Data("{}".utf8), contentType: "application/json", accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Failed to get drive info") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let id = json["resource_drive_id"] as? String, !id.isEmpty { return id }
        guard let id = json["default_drive_id"] as? String else { throw CloudDriveError.invalidResponse }
        return id
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
        let creds = await helper.tokenManager.getAppCredentials()
        guard let cid = creds?.clientId else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        let body: [String: String] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": cid, "client_secret": creds?.clientSecret ?? ""]
        let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
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
        CloudOAuthConfig(authURL: "\(oauthBase)/authorize", tokenURL: "\(oauthBase)/access_token", clientId: clientId, clientSecret: clientSecret, scopes: ["user:base", "file:all:read", "file:all:write"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://aliyun/callback")
    }
}
