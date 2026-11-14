import Foundation
import PrimuseKit

/// 115 网盘 Source — 115 开放平台 OpenAPI。
///
/// 支持设备码扫码授权及 Refresh Token 接入；刷新不依赖应用凭据。
///
/// 注意:115 的业务错误多半是 HTTP 200 + `{"state":false,"code":…}`,必须看 body(见 `Pan115APIProtocol`)。
/// 只看 HTTP 码时,出错的列目录(`data` 是空数组)会被当成空文件夹,重扫就把歌删掉;token 失效也触发不了刷新。
actor U115Source: MusicSourceConnector, OAuthCloudSource, DestructiveDirectoryListingConfirmingConnector {
    let sourceID: String
    nonisolated let preferredDeleteBatchSize = 100
    private let helper: CloudDriveHelper
    private let tokenSession: URLSession

    /// The playback identity is 115's pick_code, while recycle-bin deletion
    /// requires the numeric file id. Listing/downurl responses contain both;
    /// retain that relation for real deletion without changing stored song ids.
    private var fileIDByPickCode: [String: String] = [:]

    /// pickCode → (downloadURL, expiry)。115 直链有时效,缓存 20 分钟省去重复换链。
    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    /// 正在换的直链:起播、预读、拖动同时要同一首时共用一次 downurl。
    private var downloadURLTasks: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private static let downloadURLTTL: TimeInterval = 20 * 60

    private static let apiBase = "https://proapi.115.com/open"
    private static let passportBase = "https://passportapi.115.com/open"
    /// 115 直链对 UA 敏感:换链(downurl)与下载必须是同一个 UA。
    private static let userAgent = Pan115APIProtocol.userAgent

    init(sourceID: String, session: URLSession = .shared, requests: CloudRequestScheduler = .shared) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID, requests: requests, session: session)
        self.tokenSession = session
    }

    /// Exchange before committing so an invalid pasted token cannot replace saved credentials.
    /// 115 的 refresh_token 单次有效:这一步一成功,粘贴的那个就作废了,返回的新一对必须由调用方存下。
    func exchangeRefreshToken(_ refreshToken: String) async throws -> CloudTokenManager.Tokens {
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CloudDriveError.notAuthenticated }
        return try await self.refreshToken(.init(accessToken: "", refreshToken: token))
    }

    func connect() async throws {
        _ = try await getToken()
    }

    func disconnect() async {}

    /// 用户 UID(跨 token 刷新稳定),用于把多个挂载关联到同一 115 账户。
    func accountIdentifier() async throws -> String {
        let json = try await apiRequest(URL(string: "\(Self.apiBase)/user/info")!, missingPath: "user/info")
        let payload = json["data"] as? [String: Any] ?? json
        if let uid = payload["user_id"] { return String(describing: uid) }
        if let uid = payload["uid"] { return String(describing: uid) }
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        // path 为目录 id;根目录用 "0"。
        let cid = path.isEmpty || path == "/" ? "0" : path
        var all: [RemoteFileItem] = []
        var listedPaths = Set<String>()
        var offset = 0
        let limit = 1000
        while true {
            var comps = URLComponents(string: "\(Self.apiBase)/ufile/files")!
            comps.queryItems = [
                URLQueryItem(name: "cid", value: cid),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "show_dir", value: "1"),
            ]
            // 出错(state 为假)在 apiRequest 里就抛了:这里拿到的空数组才是真的空文件夹。
            let json = try await apiRequest(comps.url!, missingPath: cid)
            guard let items = json["data"] as? [[String: Any]] else {
                throw CloudDriveError.invalidResponse
            }
            for item in items {
                guard let name = item["fn"] as? String ?? item["n"] as? String else {
                    throw CloudDriveError.invalidResponse
                }
                // fc == "0" 目录 / "1" 文件(以官方文档为准)。
                let isDir = (item["fc"] as? String == "0") || (item["fc"] as? Int == 0)
                let size = (item["fs"] as? Int64) ?? Int64(item["fs"] as? String ?? "0") ?? 0
                let sha1 = item["sha1"] as? String
                if isDir {
                    // 目录:用目录 id 作为后续 listFiles 的 path。
                    let dirID = (item["fid"] as? String) ?? (item["cid"] as? String) ?? ""
                    guard !dirID.isEmpty, dirID != "0", listedPaths.insert(dirID).inserted else { continue }
                    all.append(RemoteFileItem(
                        name: name,
                        path: dirID,
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil,
                        revision: nil,
                        providerID: dirID,
                        parentPath: cid
                    ))
                } else {
                    // 文件:用 pick_code(pc)作为 path,取直链时需要。翻页时目录在变,同一项可能出现两次。
                    guard let pc = item["pc"] as? String, !pc.isEmpty, listedPaths.insert(pc).inserted else { continue }
                    let fileID = Self.stringValue(item["fid"] ?? item["file_id"])
                    if let fileID, !fileID.isEmpty {
                        fileIDByPickCode[pc] = fileID
                    }
                    all.append(RemoteFileItem(
                        name: name,
                        path: pc,
                        isDirectory: false,
                        size: size,
                        // upt:修改时间(Unix 秒)。只用来判断同一个文件是否被换过内容,以前没有日期的行不会因此重读。
                        modifiedDate: Pan115APIProtocol.date(fromTimestamp: item["upt"] ?? item["uet"]),
                        revision: sha1,
                        providerID: fileID,
                        parentPath: cid
                    ))
                }
            }
            offset += items.count
            // 有总数(count)就按总数翻页:服务端单页给得比 limit 少时不会漏掉后面的;没有总数才按「这页不满」收尾。
            if let total = Pan115APIProtocol.intValue(json["count"]) {
                if items.isEmpty || offset >= total { break }
            } else if items.count < limit {
                break
            }
        }
        return all
    }

    /// 以前见过的子项这次没列出来时,再独立列一遍:两遍都没有(或第二遍完整)才交给扫描当作删除。
    /// 115 偶尔回一份 state 正常但缺了几项的列表(翻页中途目录在变等),一次就信会把歌删掉。
    func listFiles(
        at path: String,
        confirmingPreviouslyObservedPaths paths: Set<String>
    ) async throws -> [RemoteFileItem] {
        let first = try await listFiles(at: path)
        let firstMissing = paths.subtracting(first.map(\.path))
        guard !firstMissing.isEmpty else { return first }
        try Task.checkCancellation()
        let second = try await listFiles(at: path)
        let secondMissing = paths.subtracting(second.map(\.path))
        guard secondMissing.isEmpty || secondMissing == firstMissing else {
            throw SourceError.connectionFailed("115 directory changed while confirming removed files")
        }
        return second
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        do {
            return try await helper.downloadToCache(request: Self.downloadRequest(url), for: path)
        } catch let error where Self.isExpiredLink(error) {
            // 直链在缓存期内提前失效:丢掉这一条,换一条再试一次。
            dropDownloadURL(for: path, ifStill: url)
            let fresh = try await getDownloadURL(for: path)
            return try await helper.downloadToCache(request: Self.downloadRequest(fresh), for: path)
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        do {
            return try await helper.rangeRequest(url: url, offset: offset, length: length, userAgent: Self.userAgent)
        } catch let error where Self.isExpiredLink(error) {
            // 直链在缓存期内提前失效:丢掉这一条,换一条再试一次(同 OneDrive)。别的读已经换上新直链时不动它。
            dropDownloadURL(for: path, ifStill: url)
            let fresh = try await getDownloadURL(for: path)
            return try await helper.rangeRequest(url: fresh, offset: offset, length: length, userAgent: Self.userAgent)
        }
    }

    /// Move files to 115's recycle bin. The OpenAPI takes file ids rather
    /// than the pick_codes Primuse uses for playback, so resolve every id and
    /// only report success after the service confirms the batch operation.
    func deleteFile(at path: String) async throws {
        try await deleteFiles(at: [path])
    }

    func deleteFiles(at paths: [String]) async throws {
        let uniquePickCodes = Array(Set(paths))
        guard !uniquePickCodes.isEmpty else { return }
        var fileIDs: [String] = []
        fileIDs.reserveCapacity(uniquePickCodes.count)
        // 扫描列目录时记下了 pick_code → 文件 id;只有这次启动后没列过的文件才要单独换一次直链拿 id。
        for pickCode in uniquePickCodes {
            fileIDs.append(try await resolveFileID(for: pickCode))
        }

        // state / code 的确认在 apiRequest 里:服务端没确认就抛错,不会当成已经删掉。
        _ = try await apiRequest(
            URL(string: "\(Self.apiBase)/ufile/delete")!,
            method: "POST",
            form: [.init(name: "file_ids", value: fileIDs.joined(separator: ","))],
            replay: .never,
            missingPath: uniquePickCodes.joined(separator: ",")
        )
        for pickCode in uniquePickCodes {
            downloadURLCache.removeValue(forKey: pickCode)
            fileIDByPickCode.removeValue(forKey: pickCode)
        }
        plog("🗑️ 115 items moved to recycle bin: \(fileIDs.count)")
    }

    // MARK: - 私有

    /// 发一个 115 OpenAPI 请求:带 Bearer 与固定 UA,校验 body 的 state / code。
    /// token 失效(HTTP 401 或业务码)在同一预算里刷新一次重试;限流按冷却退避;
    /// 文件不在只认明确的说法(`missingPath` 进错误信息)。返回顶层 JSON。
    private func apiRequest(
        _ url: URL,
        method: String = "GET",
        form: [URLQueryItem]? = nil,
        replay: RequestExecutor.Replay = .idempotent,
        missingPath: String
    ) async throws -> [String: Any] {
        let token = try await getToken()
        let session = tokenSession
        let body = form.flatMap { CloudDriveHelper.formURLEncodedBody($0) }
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            let (data, http) = try await self.helper.dataRequest(
                url: url, replay: replay, session: session,
                validate: { data, http in
                    guard (200...299).contains(http.statusCode) else { return }
                    try Self.validateEnvelope(data, http: http, missingPath: missingPath)
                }, request: { refreshed in
                    var request = URLRequest(url: url)
                    request.httpMethod = method
                    request.setValue("Bearer \(refreshed ?? tok)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    if let body {
                        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        request.httpBody = body
                    }
                    request.timeoutInterval = 60
                    return request
                }
            )
            if http.statusCode == 404 { throw CloudDriveError.fileNotFound(missingPath) }
            if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
            guard (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudDriveError.invalidResponse
            }
            return json
        }
    }

    /// 业务包络 → 连接器的错误:token 失效触发刷新,限流交给调度器冷却,文件不在报 fileNotFound
    /// (回填据此不再重试),其余带着 115 的业务码报 apiError(回填当作暂时的,下一轮再试)。
    private static func validateEnvelope(_ data: Data, http: HTTPURLResponse, missingPath: String) throws {
        guard let envelope = Pan115APIProtocol.envelope(of: data) else {
            throw CloudDriveError.invalidResponse
        }
        switch envelope {
        case .success:
            return
        case .tokenExpired:
            throw CloudDriveError.tokenExpired
        case .rateLimited:
            throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true)
        case .notFound:
            throw CloudDriveError.fileNotFound(missingPath)
        case .failure(let code, let message):
            throw CloudDriveError.apiError(code, message.isEmpty ? "115 request failed" : message)
        }
    }

    /// path 是文件的 pick_code;调 downurl 换直链。同一个 pick_code 并发要直链时共用一次请求。
    private func getDownloadURL(for pickCode: String) async throws -> URL {
        if let cached = downloadURLCache[pickCode], cached.expiresAt > Date() {
            return cached.url
        }
        if let inFlight = downloadURLTasks[pickCode] {
            let resolved = try await inFlight.task.value
            try Task.checkCancellation()
            return resolved
        }
        let taskID = UUID()
        // 换链由共享任务完成:发起的那一路被取消时,等着同一条直链的其它读不受影响。
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.requestDownloadURL(for: pickCode)
        }
        downloadURLTasks[pickCode] = (taskID, task)
        defer {
            if downloadURLTasks[pickCode]?.id == taskID { downloadURLTasks[pickCode] = nil }
        }
        let resolved = try await task.value
        try Task.checkCancellation()
        return resolved
    }

    private func requestDownloadURL(for pickCode: String) async throws -> URL {
        // 换链要带和下载同一个 UA(apiRequest 统一带上):115 按换链时的 UA 签发直链。
        let json = try await apiRequest(
            URL(string: "\(Self.apiBase)/ufile/downurl")!,
            method: "POST",
            form: [URLQueryItem(name: "pick_code", value: pickCode)],
            missingPath: pickCode
        )
        switch Pan115APIProtocol.downloadLink(in: json) {
        case .link(let fileID, let fileURL):
            fileIDByPickCode[pickCode] = fileID
            downloadURLCache[pickCode] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
            return fileURL
        case .missingFile:
            // state 正常、data 里却没有这个文件:pick_code 已经对不上文件了。
            throw CloudDriveError.fileNotFound(pickCode)
        case .unavailable(let fileID):
            fileIDByPickCode[pickCode] = fileID
            throw CloudDriveError.apiError(0, "115 returned no download address")
        }
    }

    private func dropDownloadURL(for pickCode: String, ifStill url: URL) {
        if downloadURLCache[pickCode]?.url == url { downloadURLCache.removeValue(forKey: pickCode) }
    }

    /// 直链被 CDN 拒(过期、签名对不上):Range 读报 401/403/410,整文件下载的 401 报成 tokenExpired。
    private static func isExpiredLink(_ error: Error) -> Bool {
        switch error {
        case CloudDriveError.apiError(let code, _):
            return code == 401 || code == 403 || code == 410
        case CloudDriveError.tokenExpired:
            return true
        default:
            return false
        }
    }

    private static func downloadRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func resolveFileID(for pickCode: String) async throws -> String {
        if let fileID = fileIDByPickCode[pickCode], !fileID.isEmpty { return fileID }
        _ = try await getDownloadURL(for: pickCode)
        guard let fileID = fileIDByPickCode[pickCode], !fileID.isEmpty else {
            throw CloudDriveError.fileNotFound(pickCode)
        }
        return fileID
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let int = value as? Int { return String(int) }
        return nil
    }

    private func getToken() async throws -> String {
        // proactive 路径: 本地标记过期才刷新, 与 reactive(401)路径共享 CloudTokenManager
        // 里的同一个 in-flight 去重任务, 避免并发刷新把轮换型 refresh_token 作废。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    /// 115 刷新只需 refresh_token,不需要 client_secret。
    // nonisolated: 只用 helper(Sendable)/静态常量/URLSession, 不碰可变 actor 状态,
    // 这样能作为 @Sendable 闭包传给 tokenManager.refreshDeduped / withTokenRetry。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        try await Self.refreshTokens(tokens, helper: helper, session: tokenSession)
    }

    /// 用 refresh_token 换一对新的。成功与否只看 body 里有没有 access_token(见 `Pan115APIProtocol.refreshOutcome`):
    /// 服务端一旦给出新的一对,旧的 refresh_token 就作废了,新的一定要交回去存下。
    static func refreshTokens(
        _ tokens: CloudTokenManager.Tokens,
        helper: CloudDriveHelper,
        session: URLSession
    ) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !rt.isEmpty else {
            throw CloudDriveError.tokenRefreshFailed("No refresh token")
        }
        let body = CloudDriveHelper.formURLEncodedBody([URLQueryItem(name: "refresh_token", value: rt)])
        var request = URLRequest(url: URL(string: "\(passportBase)/refreshToken")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await helper.tokenRequest(request, clientID: "", session: session)
        let http = response as? HTTPURLResponse
        switch Pan115APIProtocol.refreshOutcome(data) {
        case .refreshed(let grant):
            return .init(accessToken: grant.accessToken,
                         refreshToken: grant.refreshToken ?? rt,
                         expiresAt: Date().addingTimeInterval(grant.expiresIn ?? 7200),
                         tokenType: grant.tokenType ?? tokens.tokenType,
                         extra: tokens.extra)
        case .rateLimited:
            // 刷新太频繁:refresh_token 还能用,稍后再试;不能报成授权失效。
            throw HTTPResponseFailure(
                statusCode: http?.statusCode ?? 429,
                retryAfter: http.flatMap { HTTPResponseFailure.retryDelay(from: $0) },
                isRateLimited: true
            )
        case .invalidRefreshToken(let code, _):
            plog("115 refresh token rejected code=\(code.map { String($0) } ?? "-") sourceID=\(helper.sourceID.prefix(8))…")
            throw CloudDriveError.tokenRefreshFailed(invalidRefreshTokenReason)
        case .temporaryFailure(let code, let message):
            throw CloudDriveError.apiError(
                code ?? 503,
                message.isEmpty ? "115 token refresh temporarily unavailable" : message
            )
        }
    }

    /// refresh_token 已失效或已被用过(115 单次有效):只能重新拿一个。
    static var invalidRefreshTokenReason: String {
        String(
            localized: "pan115_refresh_token_invalid",
            defaultValue: "This refresh token is invalid or has already been used. Get a new refresh token and connect again."
        )
    }

    /// 电视端解析器与扫描共用的刷新入口(见 `CloudTokenRefreshProvider`):按 sourceID 走同一个
    /// `CloudTokenManager` 去重任务,用钥匙串里最新的那一对。钥匙串里没有这个源的 token 时返回 nil,
    /// 解析器改用同步来的凭据自己刷新。
    static func sharedTokenRefresh(
        sourceID: String,
        rejectedAccessToken: String?,
        synced: SourceCredential
    ) async throws -> CloudCredentialRefresh? {
        let helper = CloudDriveHelper(sourceID: sourceID)
        let manager = helper.tokenManager
        switch await manager.lookupTokens() {
        case .found:
            break
        case .temporarilyUnavailable(let status):
            // 钥匙串暂时读不了时不拿凭据包里可能已经作废的那个去换。
            throw CloudDriveError.credentialTemporarilyUnavailable(status)
        case .notFound, .failed:
            return nil
        }
        let refresh: @Sendable (CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens = { tokens in
            try await refreshTokens(tokens, helper: helper, session: .shared)
        }
        let trigger = rejectedAccessToken.map { CloudTokenManager.RefreshTrigger.ifMatches($0) } ?? .ifExpired
        let tokens: CloudTokenManager.Tokens
        do {
            tokens = try await manager.refreshDeduped(trigger, refresh: refresh)
        } catch CloudDriveError.tokenRefreshFailed(let reason) {
            // 钥匙串里那个被拒了,同步来的凭据里却是另一个(别的设备刷新后经凭据包先到了):用它再换一次。
            let storedRefresh = await manager.getTokens()?.refreshToken
            guard let syncedRefresh = synced.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !syncedRefresh.isEmpty, syncedRefresh != storedRefresh else {
                throw CloudDriveError.tokenRefreshFailed(reason)
            }
            let candidate = CloudTokenManager.Tokens(accessToken: synced.token ?? "", refreshToken: syncedRefresh)
            tokens = try await manager.refreshDeduped(.force) { _ in
                try await refreshTokens(candidate, helper: helper, session: .shared)
            }
        }
        return CloudCredentialRefresh(
            credential: SourceCredential(token: tokens.accessToken, refreshToken: tokens.refreshToken),
            expiresAt: tokens.expiresAt,
            tokenType: tokens.tokenType
        )
    }

    /// 授权码模式(浏览器重定向):用于 iOS,以及 macOS 不走扫码时的路径。
    /// 115 的 redirect_uri 必须是注册过的 https 域名(不收自定义 scheme),故用 welape
    /// https 中转页,页面再深链回 `primuse://pan115/callback`(靠 explicitCallbackScheme
    /// 让 ASWebAuthenticationSession 监听 primuse scheme)。
    /// 注意:tokenURL 是 authCodeToToken(非扫码用的 deviceCodeToToken),且不用 PKCE。
    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .pan115,
            authURL: "\(passportBase)/authorize",
            tokenURL: "\(passportBase)/authCodeToToken",
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: [],
            redirectURI: "https://115pan.callback.welape.com/",
            usesPKCE: false,
            explicitCallbackScheme: CloudOAuthConfig.callbackScheme
        )
    }
}
