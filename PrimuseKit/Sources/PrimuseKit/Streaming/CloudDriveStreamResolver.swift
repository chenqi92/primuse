import Foundation

/// Dropbox / OneDrive 目录浏览返回的轻量条目。`path` 保持提供方原生标识：
/// OneDrive 是 driveItem ID，Dropbox 是 display path，可直接复用为歌曲播放标识。
public struct CloudDriveDirectoryEntry: Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let path: String
    public let providerID: String?
    public let parentPath: String?
    public let modifiedDate: Date?
    public let revision: String?

    public init(
        name: String,
        isDirectory: Bool,
        size: Int64,
        path: String,
        providerID: String? = nil,
        parentPath: String? = nil,
        modifiedDate: Date? = nil,
        revision: String? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.path = path
        self.providerID = providerID
        self.parentPath = parentPath
        self.modifiedDate = modifiedDate
        self.revision = revision
    }
}

/// OAuth 刷新后的完整结果。除新的凭据外还保留过期时间与 token type，
/// 让调用方可以按 CloudTokenManager 的既有格式写回 iCloud Keychain。
public struct CloudCredentialRefresh: Sendable, Equatable {
    public let credential: SourceCredential
    public let expiresAt: Date?
    public let tokenType: String?

    public init(credential: SourceCredential, expiresAt: Date?, tokenType: String?) {
        self.credential = credential
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }
}

public typealias CloudCredentialRefreshHandler = @Sendable (
    _ sourceID: String,
    _ refresh: CloudCredentialRefresh
) async -> Void

struct CloudDriveDirectoryPage: Equatable {
    let entries: [CloudDriveDirectoryEntry]
    let nextURL: URL?
}

struct DropboxDirectoryPage: Equatable {
    let entries: [CloudDriveDirectoryEntry]
    let cursor: String?
    let hasMore: Bool
}

struct CloudOAuthTokenResponse: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let tokenType: String?
}

/// 云盘流式解析 —— 用同步下来的 OAuth 凭据换一个**预签名直链**给 AVPlayer 直接播。
///
/// 本期覆盖"直链无需额外播放头"的提供方:阿里云盘 / OneDrive / Dropbox / 123 云盘。
/// (百度网盘、115 需要 UA 固定,Google Drive 需在播放请求带 Bearer 头 —— 这些要等
/// 引擎支持自定义播放头后再接。)
///
/// 字段映射(同 iOS 各 connector):song.filePath = 提供方文件标识(阿里/123/OneDrive
/// 是 fileId,Dropbox 是 path_display);凭据来自同步包:token=access_token、
/// refreshToken、clientID/clientSecret、extra["drive_id"](阿里)。
public actor CloudDriveStreamResolver: StreamResolver {
    private var accessTokens: [String: String] = [:]   // sourceID → 当前 access token
    private var accessTokenTasks: [String: (id: UUID, forceRefresh: Bool, task: Task<String, Error>)] = [:]
    private var refreshedCredentials: [String: SourceCredential] = [:]
    private var credentialRefreshHandler: CloudCredentialRefreshHandler?
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    public func setCredentialRefreshHandler(_ handler: CloudCredentialRefreshHandler?) {
        credentialRefreshHandler = handler
    }

    public func invalidateSession(sourceID: String) {
        accessTokens[sourceID] = nil
        refreshedCredentials[sourceID] = nil
        accessTokenTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        let fileID = song.filePath
        let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
        do {
            return try await mint(
                type: source.type,
                fileID: fileID,
                token: token,
                cred: refreshedCredentials[source.id] ?? cred
            )
        } catch StreamResolveError.authFailed {
            // token 过期 → 刷新后重试一次
            let fresh = try await accessToken(for: source, cred: cred, forceRefresh: true)
            return try await mint(
                type: source.type,
                fileID: fileID,
                token: fresh,
                cred: refreshedCredentials[source.id] ?? cred
            )
        }
    }

    /// Apple TV 目录浏览 / 扫描入口。目前只开放已验证可直接播放的 OneDrive 与 Dropbox。
    public func listDirectory(
        source: MusicSource,
        credential: SourceCredential?,
        path: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        guard source.type == .oneDrive || source.type == .dropbox else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let cred = credential ?? SourceCredential()
        let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
        do {
            return try await listDirectory(type: source.type, path: path, token: token)
        } catch StreamResolveError.authFailed {
            let fresh = try await accessToken(for: source, cred: cred, forceRefresh: true)
            return try await listDirectory(type: source.type, path: path, token: fresh)
        }
    }

    // MARK: - resolve(含需自定义播放头的 Google / 115 / Drime)

    static let pan115UA = "Mozilla/5.0 Primuse/1.0"

    public func resolve(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> ResolvedStream {
        let cred = credential ?? SourceCredential()
        switch source.type {
        case .aliyunDrive, .oneDrive, .dropbox, .pan123:
            return ResolvedStream(url: try await streamURL(for: song, source: source, credential: cred))
        case .googleDrive:
            // Google:端点即下载地址,播放需带 Bearer 头(走 resource loader)。
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            let id = song.filePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&acknowledgeAbuse=true") else {
                throw StreamResolveError.cannotBuildURL
            }
            return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(token)"])
        case .pan115:
            // 115:downurl 取直链,播放需带固定 UA(走 resource loader)。
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            do {
                let url = try await mint115(pickCode: song.filePath, token: token)
                return ResolvedStream(url: url, headers: ["User-Agent": Self.pan115UA])
            } catch StreamResolveError.authFailed {
                let fresh = try await accessToken(for: source, cred: cred, forceRefresh: true)
                let url = try await mint115(pickCode: song.filePath, token: fresh)
                return ResolvedStream(url: url, headers: ["User-Agent": Self.pan115UA])
            }
        case .drime:
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            let url = try await mint(type: .drime, fileID: song.filePath, token: token, cred: cred)
            return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(token)"])
        default:
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
    }

    private func mint115(pickCode: String, token: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://proapi.115.com/open/ufile/downurl")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "pick_code=\(Self.formEncode(pickCode))".data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        try Self.checkBodyAuthenticationFailure(data)
        guard let url = Self.parse115URL(data) else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    // MARK: - access token(同步包优先;过期则按提供方刷新)

    private func accessToken(for source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = accessTokens[source.id] { return cached }
        if forceRefresh { accessTokens[source.id] = nil }
        if let inFlight = accessTokenTasks[source.id], !forceRefresh || inFlight.forceRefresh {
            return try await inFlight.task.value
        }
        let taskID = UUID()
        let effectiveCredential = refreshedCredentials[source.id] ?? cred
        let task = Task<String, Error> { [self] in
            switch source.type {
            case .pan123:
                return try await mint123Token(cred: effectiveCredential)   // 123 是 client-credentials,无 refresh_token
            case .drime:
                guard let token = effectiveCredential.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { throw StreamResolveError.missingCredential }
                return token
            default:
                if !forceRefresh, let token = effectiveCredential.token, !token.isEmpty { return token }
                return try await refreshOAuthToken(
                    sourceID: source.id,
                    type: source.type,
                    cred: effectiveCredential
                )
            }
        }
        accessTokenTasks[source.id] = (taskID, forceRefresh, task)
        let token: String
        do {
            token = try await task.value
        } catch {
            if accessTokenTasks[source.id]?.id == taskID { accessTokenTasks[source.id] = nil }
            throw error
        }
        if accessTokenTasks[source.id]?.id == taskID {
            accessTokens[source.id] = token
            accessTokenTasks[source.id] = nil
        }
        return token
    }

    // MARK: - 云盘目录列举

    private func listDirectory(
        type: MusicSourceType,
        path: String,
        token: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        let entries: [CloudDriveDirectoryEntry]
        switch type {
        case .oneDrive:
            entries = try await listOneDriveDirectory(path: path, token: token)
        case .dropbox:
            entries = try await listDropboxDirectory(path: path, token: token)
        default:
            throw StreamResolveError.unsupportedSourceType(type)
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    private func listOneDriveDirectory(
        path: String,
        token: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        let isRoot = path.isEmpty || path == "/"
        let endpoint: String
        if isRoot {
            endpoint = "https://graph.microsoft.com/v1.0/me/drive/root/children"
        } else {
            endpoint = "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.formEncode(path))/children"
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(
                name: "$select",
                value: "id,name,folder,file,size,eTag,lastModifiedDateTime,parentReference"
            ),
            URLQueryItem(name: "$top", value: "999"),
            URLQueryItem(name: "$orderby", value: "name"),
        ]
        guard let components,
              var nextURL = FormSafeQueryURLBuilder.url(from: components) else {
            throw StreamResolveError.cannotBuildURL
        }

        var entries: [CloudDriveDirectoryEntry] = []
        var seenURLs: Set<String> = []
        while true {
            guard Self.isTrustedOneDriveURL(nextURL),
                  seenURLs.insert(nextURL.absoluteString).inserted else {
                throw StreamResolveError.cannotBuildURL
            }
            var request = URLRequest(url: nextURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try Self.checkAuth(response)
            guard let page = Self.parseOneDriveDirectoryPage(data) else {
                throw StreamResolveError.cannotBuildURL
            }
            entries.append(contentsOf: page.entries)
            guard let following = page.nextURL else { break }
            nextURL = following
        }
        return entries
    }

    private func listDropboxDirectory(
        path: String,
        token: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        let folderPath = path.isEmpty || path == "/" ? "" : path
        var request = try Self.dropboxJSONRequest(
            endpoint: "files/list_folder",
            token: token,
            body: [
                "path": folderPath,
                "limit": 2_000,
                "recursive": false,
                "include_deleted": false,
                "include_mounted_folders": true,
            ]
        )
        var entries: [CloudDriveDirectoryEntry] = []
        var seenCursors: Set<String> = []
        while true {
            let (data, response) = try await session.data(for: request)
            try Self.checkAuth(response)
            guard let page = Self.parseDropboxDirectoryPage(data) else {
                throw StreamResolveError.cannotBuildURL
            }
            entries.append(contentsOf: page.entries)
            guard page.hasMore,
                  let cursor = page.cursor,
                  !cursor.isEmpty,
                  seenCursors.insert(cursor).inserted else {
                if page.hasMore { throw StreamResolveError.cannotBuildURL }
                break
            }
            request = try Self.dropboxJSONRequest(
                endpoint: "files/list_folder/continue",
                token: token,
                body: ["cursor": cursor]
            )
        }
        return entries
    }

    // MARK: - 取直链(各提供方)

    private func mint(type: MusicSourceType, fileID: String, token: String, cred: SourceCredential) async throws -> URL {
        switch type {
        case .aliyunDrive:
            let req = Self.jsonRequest(url: URL(string: "https://openapi.alipan.com/adrive/v1.0/openFile/getDownloadUrl")!,
                                       token: token,
                                       body: ["drive_id": cred.extra["drive_id"] ?? "", "file_id": fileID])
            return try await send(req, parse: Self.parseAliyunURL)
        case .oneDrive:
            let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(fileID)")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await send(req, parse: Self.parseOneDriveURL)
        case .dropbox:
            let req = Self.jsonRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!,
                                       token: token, body: ["path": fileID])
            return try await send(req, parse: Self.parseDropboxURL)
        case .pan123:
            var comp = URLComponents(string: "https://open-api.123pan.com/api/v1/file/download_info")!
            comp.queryItems = [URLQueryItem(name: "fileId", value: fileID)]
            guard let url = FormSafeQueryURLBuilder.url(from: comp) else {
                throw StreamResolveError.cannotBuildURL
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            return try await send(req, bodyAuthCodes: [401, 403], parse: Self.parse123URL)
        case .drime:
            guard let url = DrimeAPIProtocol.entryURL(id: fileID) else {
                throw StreamResolveError.cannotBuildURL
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await send(req, parse: Self.parseDrimeURL)
        default:
            throw StreamResolveError.unsupportedSourceType(type)
        }
    }

    private func mint123Token(cred: SourceCredential) async throws -> String {
        guard let cid = cred.clientID, let secret = cred.clientSecret else { throw StreamResolveError.missingCredential }
        var req = URLRequest(url: URL(string: "https://open-api.123pan.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("open_platform", forHTTPHeaderField: "Platform")
        req.httpBody = try? SafeJSONSerialization.data(withJSONObject: ["clientID": cid, "clientSecret": secret])
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let token = Self.parse123Token(data) else { throw StreamResolveError.authFailed }
        return token
    }

    private func refreshOAuthToken(
        sourceID: String,
        type: MusicSourceType,
        cred: SourceCredential
    ) async throws -> String {
        if type == .pan115 {
            // 115:passportapi 刷新,只需 refresh_token(无 client_secret)。
            guard let rt = cred.refreshToken, !rt.isEmpty else { throw StreamResolveError.missingCredential }
            let req = Self.formRequest(url: URL(string: "https://passportapi.115.com/open/refreshToken")!,
                                       fields: ["refresh_token": rt])
            let (data, response) = try await session.data(for: req)
            try Self.checkAuth(response)
            guard let token = Self.parse115AccessToken(data) else { throw StreamResolveError.authFailed }
            return token
        }
        guard let rt = cred.refreshToken, !rt.isEmpty, let cid = cred.clientID else {
            throw StreamResolveError.missingCredential
        }
        let req: URLRequest
        switch type {
        case .aliyunDrive:
            req = Self.jsonRequest(url: URL(string: "https://openapi.alipan.com/oauth/access_token")!, token: nil,
                                   body: ["grant_type": "refresh_token", "refresh_token": rt,
                                          "client_id": cid, "client_secret": cred.clientSecret ?? ""])
        case .oneDrive:
            req = Self.formRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                                   fields: ["grant_type": "refresh_token", "refresh_token": rt,
                                            "client_id": cid, "scope": "Files.ReadWrite offline_access"])
        case .dropbox:
            req = Self.formRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                                   fields: ["grant_type": "refresh_token", "refresh_token": rt,
                                            "client_id": cid, "client_secret": cred.clientSecret ?? ""])
        case .googleDrive:
            req = Self.formRequest(url: URL(string: "https://oauth2.googleapis.com/token")!,
                                   fields: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": cid])
        default:
            throw StreamResolveError.unsupportedSourceType(type)
        }
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let tokenResponse = Self.parseOAuthTokenResponse(data) else {
            throw StreamResolveError.authFailed
        }
        var refreshed = cred
        refreshed.token = tokenResponse.accessToken
        if let rotated = tokenResponse.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rotated.isEmpty {
            refreshed.refreshToken = rotated
        }
        refreshedCredentials[sourceID] = refreshed
        let expiresAt = tokenResponse.expiresIn.map { Date().addingTimeInterval($0) }
        if let credentialRefreshHandler {
            await credentialRefreshHandler(
                sourceID,
                CloudCredentialRefresh(
                    credential: refreshed,
                    expiresAt: expiresAt,
                    tokenType: tokenResponse.tokenType
                )
            )
        }
        return tokenResponse.accessToken
    }

    private func send(
        _ req: URLRequest,
        bodyAuthCodes: Set<Int> = [],
        parse: (Data) -> URL?
    ) async throws -> URL {
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        try Self.checkBodyAuthenticationFailure(data, additionalCodes: bodyAuthCodes)
        guard let url = parse(data) else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    // MARK: - 纯函数(可单测)

    static func jsonRequest(url: URL, token: String?, body: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? SafeJSONSerialization.data(withJSONObject: body)
        return req
    }

    static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        return req
    }

    static func dropboxJSONRequest(
        endpoint: String,
        token: String,
        body: [String: Any]
    ) throws -> URLRequest {
        guard let url = URL(string: "https://api.dropboxapi.com/2/\(endpoint)") else {
            throw StreamResolveError.cannotBuildURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try SafeJSONSerialization.data(withJSONObject: body)
        return request
    }

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamResolveError.authFailed }
        guard (200...299).contains(http.statusCode) else { throw StreamResolveError.badServerResponse(http.statusCode) }
    }

    static func checkBodyAuthenticationFailure(
        _ data: Data,
        additionalCodes: Set<Int> = [401, 403]
    ) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rawCode = json["code"] ?? json["errno"]
        let code: Int? = {
            if let value = rawCode as? Int { return value }
            if let value = rawCode as? NSNumber { return value.intValue }
            if let value = rawCode as? String { return Int(value) }
            return nil
        }()
        if let code, additionalCodes.contains(code) {
            throw StreamResolveError.authFailed
        }
        let errorCode = ((json["error"] as? String) ?? (json["error_code"] as? String))?
            .lowercased()
        if let errorCode,
           ["invalid_token", "token_expired", "expired_token", "unauthorized"].contains(errorCode) {
            throw StreamResolveError.authFailed
        }
    }

    static func parseAliyunURL(_ data: Data) -> URL? { stringURL(data, key: "url") }
    static func parseOneDriveURL(_ data: Data) -> URL? { stringURL(data, key: "@microsoft.graph.downloadUrl") }
    static func parseDropboxURL(_ data: Data) -> URL? { stringURL(data, key: "link") }

    static func parseDrimeURL(_ data: Data) -> URL? {
        guard let response = try? DrimeAPIProtocol.decodeEntry(data) else { return nil }
        return DrimeAPIProtocol.mediaURL(reference: response.fileEntry.url)
    }

    static func parse123URL(_ data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let d = json["data"] as? [String: Any],
              let s = d["downloadUrl"] as? String else { return nil }
        return URL(string: s)
    }

    static func parse123Token(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let d = json["data"] as? [String: Any] else { return nil }
        return d["accessToken"] as? String
    }

    static func parseOAuthAccessToken(_ data: Data) -> String? {
        parseOAuthTokenResponse(data)?.accessToken
    }

    static func parseOAuthTokenResponse(_ data: Data) -> CloudOAuthTokenResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else { return nil }
        let expiresIn: TimeInterval? = {
            if let value = json["expires_in"] as? NSNumber { return value.doubleValue }
            if let value = json["expires_in"] as? String { return TimeInterval(value) }
            return nil
        }()
        return CloudOAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: expiresIn,
            tokenType: json["token_type"] as? String
        )
    }

    static func parseOneDriveDirectoryPage(_ data: Data) -> CloudDriveDirectoryPage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else { return nil }
        var entries: [CloudDriveDirectoryEntry] = []
        entries.reserveCapacity(values.count)
        for value in values {
            guard let id = value["id"] as? String,
                  !id.isEmpty,
                  let name = value["name"] as? String,
                  !name.isEmpty else { return nil }
            entries.append(CloudDriveDirectoryEntry(
                name: name,
                isDirectory: value["folder"] != nil,
                size: int64Value(value["size"]),
                path: id,
                parentPath: (value["parentReference"] as? [String: Any])?["id"] as? String,
                modifiedDate: dateValue(value["lastModifiedDateTime"]),
                revision: value["eTag"] as? String
            ))
        }
        let nextURL: URL?
        if let rawNext = json["@odata.nextLink"] as? String {
            guard !rawNext.isEmpty,
                  let parsed = URL(string: rawNext),
                  isTrustedOneDriveURL(parsed) else { return nil }
            nextURL = parsed
        } else {
            nextURL = nil
        }
        return CloudDriveDirectoryPage(entries: entries, nextURL: nextURL)
    }

    static func parseDropboxDirectoryPage(_ data: Data) -> DropboxDirectoryPage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["entries"] as? [[String: Any]] else { return nil }
        var entries: [CloudDriveDirectoryEntry] = []
        entries.reserveCapacity(values.count)
        for value in values {
            guard let tag = value[".tag"] as? String else { return nil }
            // Dropbox may include deleted rows when an old cursor is resumed.
            // Fresh directory scans request include_deleted=false, but ignoring
            // an explicit deleted row keeps parsing defensive and non-destructive.
            if tag == "deleted" { continue }
            guard (tag == "file" || tag == "folder"),
                  let name = value["name"] as? String,
                  !name.isEmpty,
                  let path = (value["path_display"] as? String)
                    ?? (value["path_lower"] as? String),
                  !path.isEmpty else { return nil }
            entries.append(CloudDriveDirectoryEntry(
                name: name,
                isDirectory: tag == "folder",
                size: int64Value(value["size"]),
                path: path,
                providerID: value["id"] as? String,
                modifiedDate: dateValue(
                    value["server_modified"] ?? value["client_modified"]
                ),
                revision: (value["content_hash"] as? String)
                    ?? (value["rev"] as? String)
            ))
        }
        return DropboxDirectoryPage(
            entries: entries,
            cursor: json["cursor"] as? String,
            hasMore: json["has_more"] as? Bool ?? false
        )
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func isTrustedOneDriveURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "graph.microsoft.com"
    }

    static func parse115AccessToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = json["data"] as? [String: Any], let t = d["access_token"] as? String { return t }
        return json["access_token"] as? String
    }

    /// 115 downurl 响应:{"data":{"<file_id>":{"url":{"url":"https://..."}}}}
    static func parse115URL(_ data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let first = payload.values.first as? [String: Any],
              let urlField = first["url"] as? [String: Any],
              let s = urlField["url"] as? String else { return nil }
        return URL(string: s)
    }

    private static func stringURL(_ data: Data, key: String) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = json[key] as? String else { return nil }
        return URL(string: s)
    }
}
