import Foundation

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
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    public func invalidateSession(sourceID: String) {
        accessTokens[sourceID] = nil
        accessTokenTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        let fileID = song.filePath
        let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
        do {
            return try await mint(type: source.type, fileID: fileID, token: token, cred: cred)
        } catch StreamResolveError.authFailed {
            // token 过期 → 刷新后重试一次
            let fresh = try await accessToken(for: source, cred: cred, forceRefresh: true)
            return try await mint(type: source.type, fileID: fileID, token: fresh, cred: cred)
        }
    }

    // MARK: - resolve(含需自定义播放头的 Google / 115)

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
        let task = Task<String, Error> { [self] in
            switch source.type {
            case .pan123:
                return try await mint123Token(cred: cred)   // 123 是 client-credentials,无 refresh_token
            default:
                if !forceRefresh, let token = cred.token, !token.isEmpty { return token }
                return try await refreshOAuthToken(type: source.type, cred: cred)
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
            var req = URLRequest(url: comp.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            return try await send(req, parse: Self.parse123URL)
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["clientID": cid, "clientSecret": secret])
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let token = Self.parse123Token(data) else { throw StreamResolveError.authFailed }
        return token
    }

    private func refreshOAuthToken(type: MusicSourceType, cred: SourceCredential) async throws -> String {
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
                                            "client_id": cid, "scope": "Files.Read offline_access"])
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
        guard let token = Self.parseOAuthAccessToken(data) else { throw StreamResolveError.authFailed }
        return token
    }

    private func send(_ req: URLRequest, parse: (Data) -> URL?) async throws -> URL {
        let (data, response) = try await session.data(for: req)
        try Self.checkAuth(response)
        guard let url = parse(data) else { throw StreamResolveError.cannotBuildURL }
        return url
    }

    // MARK: - 纯函数(可单测)

    static func jsonRequest(url: URL, token: String?, body: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        return req
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

    static func parseAliyunURL(_ data: Data) -> URL? { stringURL(data, key: "url") }
    static func parseOneDriveURL(_ data: Data) -> URL? { stringURL(data, key: "@microsoft.graph.downloadUrl") }
    static func parseDropboxURL(_ data: Data) -> URL? { stringURL(data, key: "link") }

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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["access_token"] as? String
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
