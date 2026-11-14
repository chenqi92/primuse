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

/// 电视端把某类云盘的 token 交回 App 里和扫描共用的那一条刷新路径(钥匙串里的 `CloudTokenManager`):
/// 同一个源在整个进程里只有一个刷新任务,用的是钥匙串里最新的那一对,单次有效的 refresh_token
/// 不会被扫描和播放各拿一次。`rejectedAccessToken` 是刚被服务端拒掉的 access token(没有被拒、
/// 只是手里没有可用 token 时为 nil);`syncedCredential` 是随凭据包同步来的那份。
/// 返回 nil 表示钥匙串里没有这个源的 token,解析器改用同步来的凭据自己刷新。
public typealias CloudTokenRefreshProvider = @Sendable (
    _ sourceID: String,
    _ rejectedAccessToken: String?,
    _ syncedCredential: SourceCredential
) async throws -> CloudCredentialRefresh?

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
    private var tokenRefreshProviders: [MusicSourceType: CloudTokenRefreshProvider] = [:]
    private let session: URLSession
    private let requests: CloudResolverRequests

    public init(session: URLSession? = nil, quotaRegistry: RequestQuotaRegistry = .shared) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = session ?? URLSession(configuration: cfg)
        self.requests = CloudResolverRequests(registry: quotaRegistry)
    }

    public func setCredentialRefreshHandler(_ handler: CloudCredentialRefreshHandler?) {
        credentialRefreshHandler = handler
    }

    public func setTokenRefreshProvider(_ provider: CloudTokenRefreshProvider?, for type: MusicSourceType) {
        tokenRefreshProviders[type] = provider
    }

    public func invalidateSession(sourceID: String) async {
        accessTokens[sourceID] = nil
        refreshedCredentials[sourceID] = nil
        accessTokenTasks.removeValue(forKey: sourceID)?.task.cancel()
    }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        let cred = credential ?? SourceCredential()
        return try await CloudResolverRequests.$account.withValue(.init(source: source, credential: cred)) {
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            return try await mint(type: source.type, fileID: song.filePath, token: token,
                cred: refreshedCredentials[source.id] ?? cred)
        }
    }

    /// Apple TV directory browsing and scanning, including authenticated pagination.
    public func listDirectory(
        source: MusicSource, credential: SourceCredential?, path: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        guard source.type == .oneDrive || source.type == .dropbox else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let cred = credential ?? SourceCredential()
        return try await CloudResolverRequests.$account.withValue(.init(source: source, credential: cred)) {
            let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
            return try await listDirectory(type: source.type, path: path, token: token)
        }
    }

    // MARK: - resolve(含需自定义播放头的 Google / 115 / Drime)

    static let pan115UA = Pan115APIProtocol.userAgent

    public func resolve(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> ResolvedStream {
        let cred = credential ?? SourceCredential()
        return try await CloudResolverRequests.$account.withValue(.init(source: source, credential: cred)) {
            switch source.type {
            case .aliyunDrive, .oneDrive, .dropbox, .pan123, .guangya, .pcloud:
                return ResolvedStream(url: try await streamURL(for: song, source: source, credential: cred))
            case .googleDrive:
                // Google:端点即下载地址,播放需带 Bearer 头(走 resource loader)。
                let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
                let id = song.filePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&acknowledgeAbuse=true") else {
                    throw StreamResolveError.cannotBuildURL
                }
                return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(accessTokens[source.id] ?? token)"])
            case .pan115:
                // 115:downurl 取直链,播放需带固定 UA(走 resource loader)。
                let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
                let url = try await mint115(pickCode: song.filePath, token: token)
                return ResolvedStream(url: url, headers: ["User-Agent": Self.pan115UA])
            case .drime:
                let token = try await accessToken(for: source, cred: cred, forceRefresh: false)
                let url = try await mint(type: .drime, fileID: song.filePath, token: token, cred: cred)
                return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(accessTokens[source.id] ?? token)"])
            default:
                throw StreamResolveError.unsupportedSourceType(source.type)
            }
        }
    }

    private func mint115(pickCode: String, token: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://proapi.115.com/open/ufile/downurl")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 115 按换链时的 UA 签发直链:这里和播放(resolve 交给播放器的头)必须是同一个 UA。
        req.setValue(Self.pan115UA, forHTTPHeaderField: "User-Agent")
        req.httpBody = "pick_code=\(Self.formEncode(pickCode))".data(using: .utf8)
        let data = try await read(req, bodyAuthCodes: [401, 403])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamResolveError.cannotBuildURL
        }
        switch Pan115APIProtocol.downloadLink(in: json) {
        case .link(_, let url):
            return url
        case .missingFile:
            throw StreamResolveError.badServerResponse(404)
        case .unavailable:
            throw StreamResolveError.cannotBuildURL
        }
    }

    private func read(_ request: URLRequest, bodyAuthCodes: Set<Int> = []) async throws -> Data {
        guard let account = CloudResolverRequests.account, let url = request.url else {
            throw StreamResolveError.cannotBuildURL
        }
        let attempt = CloudResolverReadAttempt()
        return try await requests.execute(url: url, account: account,
            replay: .idempotent,
            recover: { error in
                let unauthorized = CloudResolverRequests.isAuthenticationFailure(error)
                guard unauthorized, await attempt.claimRecovery() else { return false }
                try await self.renew(account: account, rejectedToken: await attempt.token)
                return true
            }, operation: {
                var request = request
                let token = try await self.accessToken(for: account.source, cred: account.credential, forceRefresh: false)
                await attempt.record(token: token)
                if request.value(forHTTPHeaderField: "Authorization") != nil {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await self.session.data(for: request)
                try Self.validateResponse(data, response: response, type: account.source.type)
                try Self.checkBodyAuthenticationFailure(data, additionalCodes: bodyAuthCodes)
                return data
            })
    }

    private func renew(account: CloudResolverRequests.Account, rejectedToken: String?) async throws {
        if let cached = accessTokens[account.source.id], let rejectedToken, cached != rejectedToken { return }
        _ = try await accessToken(for: account.source, cred: account.credential, forceRefresh: true)
    }

    private func tokenRequest(_ request: URLRequest) async throws -> Data {
        guard let account = CloudResolverRequests.account, let url = request.url else {
            throw StreamResolveError.cannotBuildURL
        }
        return try await requests.execute(url: url, account: account,
            replay: .never, operation: { [session] in
                let (data, response) = try await session.data(for: request)
                try Self.validateResponse(data, response: response, type: account.source.type)
                return data
            })
    }

    private static func validateResponse(_ data: Data, response: URLResponse, type: MusicSourceType) throws {
        let http = try CloudResolverRequests.validate(data, response: response)
        if type == .pan123,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["code"] as? NSNumber)?.intValue == 429 || (json["code"] as? String) == "429" {
            throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true)
        }
        if type == .pan115 {
            try validatePan115Envelope(data, http: http)
        }
    }

    /// 115 的业务错误是 HTTP 200 + `state:false`:token 失效交给 read 的刷新重试,限流进冷却,
    /// 其余带着业务码报出来,不再当成「拿不到直链」。刷新接口只认限流(要进 token 端点的冷却),
    /// 其余结果由刷新那一步自己判断。
    private static func validatePan115Envelope(_ data: Data, http: HTTPURLResponse) throws {
        let host = http.url?.host?.lowercased()
        if host == Pan115APIProtocol.passportHost {
            if Pan115APIProtocol.refreshOutcome(data) == .rateLimited {
                throw HTTPResponseFailure(statusCode: http.statusCode, body: Data(),
                    retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true)
            }
            return
        }
        guard Pan115APIProtocol.isAPIHost(host),
              let envelope = Pan115APIProtocol.envelope(of: data) else { return }
        switch envelope {
        case .success:
            return
        case .tokenExpired:
            throw StreamResolveError.authFailed
        case .rateLimited:
            throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true)
        case .notFound:
            throw StreamResolveError.badServerResponse(404)
        case .failure(let code, _):
            throw StreamResolveError.badServerResponse(code)
        }
    }

    // MARK: - access token(同步包优先;过期则按提供方刷新)

    private func accessToken(for source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = accessTokens[source.id] { return cached }
        if forceRefresh { accessTokens[source.id] = nil }
        if let inFlight = accessTokenTasks[source.id], !forceRefresh || inFlight.forceRefresh {
            return try await CloudResolverRequests.wait(for: inFlight.task)
        }
        let taskID = UUID()
        let effectiveCredential = refreshedCredentials[source.id] ?? cred
        let task = Task<String, Error> { [self] in
            // Completion owns cleanup/cache publication, even if the initiating
            // waiter has already cancelled. A replaced task cannot clear its successor.
            defer {
                if accessTokenTasks[source.id]?.id == taskID { accessTokenTasks[source.id] = nil }
            }
            let token = try await loadAccessToken(source: source, cred: effectiveCredential, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            if accessTokenTasks[source.id]?.id == taskID { accessTokens[source.id] = token }
            return token
        }
        accessTokenTasks[source.id] = (taskID, forceRefresh, task)
        return try await CloudResolverRequests.wait(for: task)
    }

    private func loadAccessToken(source: MusicSource, cred: SourceCredential, forceRefresh: Bool) async throws -> String {
        switch source.type {
        case .pan123:
            return try await mint123Token(cred: cred)   // 123 是 client-credentials,无 refresh_token
        case .drime:
            guard let token = cred.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { throw StreamResolveError.missingCredential }
            return token
        default:
            // 电视端 115:token 以钥匙串里和扫描共用的那一对为准(见 `CloudTokenRefreshProvider`)。
            if let provider = tokenRefreshProviders[source.type],
               let shared = try await provider(source.id, forceRefresh ? cred.token : nil, cred) {
                return try await adoptSharedRefresh(shared, sourceID: source.id, cred: cred)
            }
            if !forceRefresh, let token = cred.token, !token.isEmpty { return token }
            return try await refreshOAuthToken(
                sourceID: source.id,
                type: source.type,
                cred: cred
            )
        }
    }

    /// 共用刷新路径给的 token:记下来给后面的请求用;和手里的那份不同时照常回写(凭据包里那份旧的也换掉)。
    private func adoptSharedRefresh(
        _ shared: CloudCredentialRefresh,
        sourceID: String,
        cred: SourceCredential
    ) async throws -> String {
        guard let accessToken = shared.credential.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { throw StreamResolveError.authFailed }
        var refreshed = cred
        refreshed.token = accessToken
        if let rotated = shared.credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rotated.isEmpty {
            refreshed.refreshToken = rotated
        }
        refreshedCredentials[sourceID] = refreshed
        if refreshed != cred, let credentialRefreshHandler {
            await credentialRefreshHandler(
                sourceID,
                CloudCredentialRefresh(credential: refreshed, expiresAt: shared.expiresAt, tokenType: shared.tokenType)
            )
        }
        return accessToken
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
            let data = try await read(request)
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
            let data = try await read(request)
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
        case .guangya:
            guard let config = GuangYaAPIProtocol.bundledAppConfig() else {
                throw StreamResolveError.missingCredential
            }
            guard let url = GuangYaAPIProtocol.downloadURL(fileID: fileID) else {
                throw StreamResolveError.cannotBuildURL
            }
            var req = URLRequest(url: url)
            for (field, value) in GuangYaAPIProtocol.businessHeaders(
                accessToken: token,
                config: config
            ) {
                req.setValue(value, forHTTPHeaderField: field)
            }
            // 117 = access token 失效。它走 HTTP 401,但把业务码也列进来,
            // 免得服务端哪天改成 200 + 117 后刷新链路静默失效。
            return try await send(
                req,
                bodyAuthCodes: [GuangYaAPIProtocol.ResultCode.invalidAccessToken],
                parse: Self.parseGuangYaURL
            )
        case .pcloud:
            // 打账号所在区的那台主机;直链本身带签名,播放时不再需要 token。
            guard let id = PCloudAPIProtocol.fileID(from: fileID),
                  let url = PCloudAPIProtocol.fileLinkURL(
                      host: PCloudAPIProtocol.apiHost(from: cred.extra),
                      fileID: id
                  ) else {
                throw StreamResolveError.cannotBuildURL
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data = try await read(req)
            // pCloud 的业务错误一律 HTTP 200 + result 码。token 无效没法刷新,只能重新授权,
            // 所以不进 read 的刷新重试,直接报鉴权失败。
            if let envelope = PCloudAPIProtocol.parseEnvelope(data), !envelope.isSuccess {
                if PCloudAPIProtocol.indicatesInvalidToken(envelope.result) {
                    throw StreamResolveError.authFailed
                }
                throw StreamResolveError.badServerResponse(envelope.result)
            }
            guard let link = PCloudAPIProtocol.parseFileLink(data) else {
                throw StreamResolveError.cannotBuildURL
            }
            return link.url
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
        let data = try await tokenRequest(req)
        guard let token = Self.parse123Token(data) else { throw StreamResolveError.authFailed }
        return token
    }

    private func refreshOAuthToken(
        sourceID: String,
        type: MusicSourceType,
        cred: SourceCredential
    ) async throws -> String {
        guard let rt = cred.refreshToken, !rt.isEmpty else { throw StreamResolveError.missingCredential }
        let tokenResponse: CloudOAuthTokenResponse
        if type == .pan115 {
            // 115:passportapi 刷新,只需 refresh_token(无 client_secret)。115 的 refresh_token 是轮换型的:
            // 刷新一次旧的就作废,新的必须和其它提供方一样写回凭据(再经 iCloud 钥匙串同步给别的设备),
            // 否则下一次刷新拿旧 refresh_token 必然失败,而且这台设备一刷新,别的设备手里的那份也跟着失效。
            let req = Self.formRequest(url: URL(string: "https://passportapi.115.com/open/refreshToken")!,
                                       fields: ["refresh_token": rt])
            let data = try await tokenRequest(req)
            switch Pan115APIProtocol.refreshOutcome(data) {
            case .refreshed(let grant):
                tokenResponse = CloudOAuthTokenResponse(
                    accessToken: grant.accessToken,
                    refreshToken: grant.refreshToken,
                    expiresIn: grant.expiresIn,
                    tokenType: grant.tokenType
                )
            case .rateLimited:
                throw HTTPResponseFailure(statusCode: 429, isRateLimited: true)
            case .invalidRefreshToken:
                throw StreamResolveError.authFailed
            case .temporaryFailure(let code, _):
                throw StreamResolveError.badServerResponse(code ?? 503)
            }
        } else {
            tokenResponse = try await refreshStandardOAuthToken(type: type, refreshToken: rt, cred: cred)
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

    /// 标准 OAuth refresh_token 授权(阿里 / OneDrive / Dropbox / Google / 光鸭)。
    private func refreshStandardOAuthToken(
        type: MusicSourceType,
        refreshToken rt: String,
        cred: SourceCredential
    ) async throws -> CloudOAuthTokenResponse {
        guard let cid = cred.clientID else {
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
        case .guangya:
            req = Self.jsonRequest(
                url: GuangYaAPIProtocol.tokenURL,
                token: nil,
                body: ["client_id": cid, "grant_type": "refresh_token", "refresh_token": rt]
            )
        default:
            throw StreamResolveError.unsupportedSourceType(type)
        }
        let data = try await tokenRequest(req)
        guard let tokenResponse = Self.parseOAuthTokenResponse(data) else {
            throw StreamResolveError.authFailed
        }
        return tokenResponse
    }

    private func send(
        _ req: URLRequest,
        bodyAuthCodes: Set<Int> = [],
        parse: (Data) -> URL?
    ) async throws -> URL {
        let data = try await read(req, bodyAuthCodes: bodyAuthCodes)
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

    static func parseGuangYaURL(_ data: Data) -> URL? {
        GuangYaAPIProtocol.parseDownloadTicket(data)?.url
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
        parse115TokenResponse(data)?.accessToken
    }

    /// 115 刷新响应:`{"state":1,"code":0,"error":"","data":{"access_token":…,"refresh_token":…,"expires_in":7200}}`,
    /// 也兼容直接放在顶层的写法。判定见 `Pan115APIProtocol.refreshOutcome`。
    static func parse115TokenResponse(_ data: Data) -> CloudOAuthTokenResponse? {
        guard case .refreshed(let grant) = Pan115APIProtocol.refreshOutcome(data) else { return nil }
        return CloudOAuthTokenResponse(
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken,
            expiresIn: grant.expiresIn,
            tokenType: grant.tokenType
        )
    }

    /// 115 downurl 响应:{"data":{"<file_id>":{"url":{"url":"https://..."}}}}
    static func parse115URL(_ data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              case .link(_, let url) = Pan115APIProtocol.downloadLink(in: json) else { return nil }
        return url
    }

    private static func stringURL(_ data: Data, key: String) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = json[key] as? String else { return nil }
        return URL(string: s)
    }
}

// MARK: - 115 开放平台

/// 115 开放平台(proapi / passportapi)的约定。iPhone / iPad / Mac 的 `U115Source` 与电视端的解析器共用这一份,
/// 对同一份响应得出同样的结论。
///
/// 115 的业务错误多半是 HTTP 200 + `{"state":false,"code":…,"message":…}`;成功的响应里也常带
/// `"error":""`、`"errno":0` 这类空字段。所以只认 `state` / `code`:不能拿「有 error 字段」当失败,
/// 也不能只看 HTTP 码(出错时列目录的 `data` 是空数组,会被当成空文件夹)。
public enum Pan115APIProtocol {
    /// 换直链(downurl)和用直链下载必须带同一个 UA:115 按换链时的 UA 签发直链,对不上会被拒。
    public static let userAgent = "Mozilla/5.0 Primuse/1.0"
    public static let apiHost = "proapi.115.com"
    public static let passportHost = "passportapi.115.com"

    /// 同一个账号打 115 接口(列目录、换直链、用户信息)的最小间隔与同时在途数。115 对接口频率很敏感,
    /// OpenList 默认每秒一个请求;这里取 0.5 秒、两路,被限流时还有业务码识别与冷却兜底。
    public static let minimumRequestInterval: TimeInterval = 0.5
    public static let maximumConcurrentRequests = 2

    public static func isAPIHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == apiHost || host == passportHost
    }

    // MARK: 业务包络

    public enum Envelope: Equatable, Sendable {
        case success
        /// access_token 失效(业务码 99、401,或 4014 开头的授权类码):刷新一次再试。
        case tokenExpired
        /// 请求太频繁、到了上限:按限流冷却、退避。
        case rateLimited
        /// 文件或目录已经不在了。
        case notFound
        case failure(code: Int, message: String)
    }

    /// 一份接口响应的业务结果。不是 JSON 对象时返回 nil。
    public static func envelope(of data: Data) -> Envelope? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return envelope(of: json)
    }

    /// `state` 是准:真就成功,假就按业务码分类。没有 `state` 的老写法看 `code`(缺省或 0 为成功)。
    public static func envelope(of json: [String: Any]) -> Envelope {
        let code = businessCode(in: json)
        if let state = boolValue(json["state"]) {
            if state { return .success }
        } else if code == nil || code == 0 {
            return .success
        }
        let message = providerMessage(in: json)
        if let code {
            if code == refreshRateLimitedCode || code == 429 { return .rateLimited }
            if isAuthorizationCode(code) { return .tokenExpired }
        }
        if mentionsRateLimit(message) { return .rateLimited }
        if mentionsMissingItem(message) { return .notFound }
        return .failure(code: code ?? 0, message: message)
    }

    /// 99(未登录)、401,以及 4014xxxx 这一族(40140123~40140126 是 access_token 格式错、签名错、
    /// 已失效、校验失败)。4010xxxx(参数缺失、设备码)与 4011xxxx(请求异常)不是 token 的问题。
    static func isAuthorizationCode(_ code: Int) -> Bool {
        code == 99 || code == 401 || (40_140_000...40_149_999).contains(code)
    }

    // MARK: 刷新 token

    public struct TokenGrant: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
        public let tokenType: String?

        public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval?, tokenType: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
            self.tokenType = tokenType
        }
    }

    public enum RefreshOutcome: Equatable, Sendable {
        case refreshed(TokenGrant)
        /// 刷新太频繁(40140117)或别的限流说法:稍后再试,refresh_token 本身还能用。
        case rateLimited
        /// refresh_token 格式或签名不对、已解除授权、已过期、已经被用过或被新的一对顶替(40140114~40140120):
        /// 只能重新拿一个。
        case invalidRefreshToken(code: Int?, message: String)
        /// 服务端暂时出错,或说成功却没给 token:refresh_token 没被认定失效,下次照样能试。
        case temporaryFailure(code: Int?, message: String)
    }

    static let refreshRateLimitedCode = 40_140_117
    static let invalidRefreshTokenCodes: Set<Int> = [40_140_114, 40_140_115, 40_140_116, 40_140_119, 40_140_120]
    /// 「请求异常需要重试」「access_token 刷新失败」。
    static let temporaryRefreshCodes: Set<Int> = [40_110_000, 40_140_121]

    /// 刷新 / 粘贴 refresh_token 换 token 的响应。只要 body 里有 access_token(且 `state` 不是假),就是成功:
    /// 服务端此时已经把旧的 refresh_token 作废,新的一对必须收下,不能因为别的字段(比如空的 `error`)丢掉。
    public static func refreshOutcome(_ data: Data) -> RefreshOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .temporaryFailure(code: nil, message: "")
        }
        let state = boolValue(json["state"])
        let code = businessCode(in: json)
        if state != false,
           let grant = tokenGrant(in: json["data"] as? [String: Any] ?? [:]) ?? tokenGrant(in: json) {
            return .refreshed(grant)
        }
        let message = providerMessage(in: json)
        if state == true || (state == nil && (code ?? 0) == 0) {
            return .temporaryFailure(code: code, message: message)
        }
        if let code {
            if code == refreshRateLimitedCode { return .rateLimited }
            if invalidRefreshTokenCodes.contains(code) || code == 99 {
                return .invalidRefreshToken(code: code, message: message)
            }
            if temporaryRefreshCodes.contains(code) { return .temporaryFailure(code: code, message: message) }
        }
        // 4014xxxx 这一族(应用、开发者、授权状态)没有一个是刷新一下就好的;放在说法判断前面,
        // 免得「超出授权应用个数上限」这类说法被当成限流。
        if let code, isAuthorizationCode(code) { return .invalidRefreshToken(code: code, message: message) }
        if mentionsRateLimit(message) { return .rateLimited }
        return .temporaryFailure(code: code, message: message)
    }

    static func tokenGrant(in payload: [String: Any]) -> TokenGrant? {
        guard let accessToken = nonEmptyString(payload["access_token"]) else { return nil }
        return TokenGrant(
            accessToken: accessToken,
            refreshToken: nonEmptyString(payload["refresh_token"]),
            expiresIn: doubleValue(payload["expires_in"]),
            tokenType: nonEmptyString(payload["token_type"])
        )
    }

    // MARK: 直链与列表字段

    public enum DownloadLink: Equatable, Sendable {
        case link(fileID: String, url: URL)
        /// `data` 里没有这个文件:pick_code 已经对不上文件了。
        case missingFile
        /// 有这个文件但没给地址(还在处理、被屏蔽等),不算文件不在。
        case unavailable(fileID: String)
    }

    /// downurl 响应:`{"data":{"<file_id>":{"url":{"url":"https://…"}}}}`。
    public static func downloadLink(in json: [String: Any]) -> DownloadLink {
        guard let payload = json["data"] as? [String: Any], let entry = payload.first else { return .missingFile }
        let fields = entry.value as? [String: Any] ?? [:]
        let rawLink = (fields["url"] as? [String: Any])?["url"] as? String ?? fields["url"] as? String
        guard let link = rawLink?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty,
              let url = URL(string: link) else { return .unavailable(fileID: entry.key) }
        return .link(fileID: entry.key, url: url)
    }

    /// 列表里的 `upt` / `uet`:Unix 秒(字符串或数字);误给成毫秒时也认。
    public static func date(fromTimestamp value: Any?) -> Date? {
        guard let seconds = doubleValue(value), seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    public static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    // MARK: 私有

    static let rateLimitWords = ["频繁", "上限", "too many", "rate limit", "frequent"]
    static let missingItemWords = ["不存在", "已删除", "已被删除", "not exist", "not found"]

    static func mentionsRateLimit(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return rateLimitWords.contains { lowered.contains($0) }
    }

    static func mentionsMissingItem(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return missingItemWords.contains { lowered.contains($0) }
    }

    /// `code` 优先;没有 `code` 时看 `errno`。
    static func businessCode(in json: [String: Any]) -> Int? {
        intValue(json["code"]) ?? intValue(json["errno"])
    }

    static func providerMessage(in json: [String: Any]) -> String {
        for key in ["message", "error", "msg", "error_msg"] {
            if let text = nonEmptyString(json[key]) { return String(text.prefix(300)) }
        }
        return ""
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
