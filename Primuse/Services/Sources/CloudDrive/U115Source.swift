import Foundation
import PrimuseKit

/// 115 网盘 Source — 115 开放平台 OpenAPI。
///
/// 支持设备码扫码授权及 Refresh Token 接入；刷新不依赖应用凭据。
///
/// 注意:115 的业务错误多半是 HTTP 200 + `{"state":false,"code":…}`,必须看 body(见 `Pan115APIProtocol`)。
/// 只看 HTTP 码时,出错的列目录(`data` 是空数组)会被当成空文件夹,重扫就把歌删掉;token 失效也触发不了刷新。
actor U115Source: MusicSourceConnector, OAuthCloudSource, DestructiveDirectoryListingConfirmingConnector,
    EmbeddedMetadataWritebackAdapter, LyricsSidecarTargetResolving, RemoteCoverSidecarLocating, RemoteFileDisplayNameProviding {
    let sourceID: String
    nonisolated let preferredDeleteBatchSize = 100
    nonisolated let supportsSidecarWriting = true
    private var parentByPickCode: [String: String] = [:]
    private let helper: CloudDriveHelper
    private let tokenSession: URLSession
    private let sleep: @Sendable (TimeInterval) async throws -> Void

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

    init(
        sourceID: String,
        session: URLSession = .shared,
        requests: CloudRequestScheduler = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            guard interval > 0 else { return }
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID, requests: requests, session: session,
                                      validateResponse: Self.checkForBlockedRequest)
        self.tokenSession = session
        self.sleep = sleep
    }

    /// 115 的请求拦截页会返回 405。让同账号的请求一起等待，扫描可保留未读目录。
    private static func checkForBlockedRequest(_ data: Data, _ http: HTTPURLResponse) throws {
        guard http.statusCode == 405, Pan115APIProtocol.isAPIHost(http.url?.host),
              data.range(of: Data("waf_agent_protection_triggered".utf8)) != nil else { return }
        throw HTTPResponseFailure(statusCode: 405,
                                  retryAfter: HTTPResponseFailure.retryDelay(from: http) ?? 5 * 60,
                                  isRateLimited: true, isRetryable: false)
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
                URLQueryItem(name: "cur", value: "1"),
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
                    guard let dirID = Self.stringValue(item["fid"] ?? item["cid"]),
                          !dirID.isEmpty, dirID != "0" else { throw CloudDriveError.invalidResponse }
                    guard listedPaths.insert(dirID).inserted else { continue }
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
                        parentByPickCode[pc] = cid
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
                if offset >= total { break }
                guard !items.isEmpty else { throw CloudDriveError.invalidResponse }
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
        func visible(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
            items.filter { $0.isDirectory || paths.contains($0.path) || !Self.isInternalStagingName($0.name) }
        }
        let first = visible(try await listFiles(at: path))
        let firstMissing = paths.subtracting(first.map(\.path))
        guard !firstMissing.isEmpty else { return first }
        try Task.checkCancellation()
        let second = visible(try await listFiles(at: path))
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
        helper.scanAudioFiles(from: path) { [self] p in
            try await listFiles(at: p).filter { $0.isDirectory || !Self.isInternalStagingName($0.name) }
        }
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
            parentByPickCode.removeValue(forKey: pickCode)
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
            if http.statusCode == 403 { throw CloudDriveError.permissionDenied(replay == .never ? .fileWrite : .fileRead) }
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

extension U115Source {
    private func fileContext(_ path: String) async throws -> (file: RemoteFileItem, parent: String, siblings: [RemoteFileItem]) {
        let id = try await resolveFileID(for: path)
        if let parent = parentByPickCode[path] {
            let items = try await listFiles(at: parent)
            if let file = items.first(where: { !$0.isDirectory && $0.path == path && $0.providerID == id }) {
                return (file, parent, items)
            }
        }
        var url = URLComponents(string: Self.apiBase + "/folder/get_info")!
        url.queryItems = [.init(name: "file_id", value: id)]
        let json = try await apiRequest(url.url!, missingPath: path)
        let detail = json["data"] as? [String: Any] ?? (json["data"] as? [[String: Any]])?.first
        guard let detail, Self.stringValue(detail["file_id"]) == id else { throw CloudDriveError.invalidResponse }
        let ancestors = (detail["paths"] as? [[String: Any]])?.compactMap { Self.stringValue($0["file_id"]) }
        let parent = Self.stringValue(detail["parent_id"]) ?? ancestors?.last(where: { $0 != id }) ?? "0"
        let items = try await listFiles(at: parent)
        guard let file = items.first(where: { !$0.isDirectory && $0.path == path && $0.providerID == id }) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        return (file, parent, items)
    }

    private func state(_ item: RemoteFileItem) throws -> EmbeddedMetadataRemoteFileState {
        guard let sha = item.revision, sha.count == 40, sha.allSatisfy(\.isHexDigit),
              let parent = item.parentPath, let id = item.providerID, !id.isEmpty else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        return .init(fileSize: item.size, modifiedDate: item.modifiedDate, revision: sha,
                     replacementToken: parent + "/" + id + "/" + item.name)
    }

    func displayName(for path: String) async throws -> String? {
        try await fileContext(path).file.name
    }

    func existingCoverSidecar(for path: String) async throws -> RemoteFileItem? {
        let context = try await fileContext(path)
        let name = (context.file.name as NSString).deletingPathExtension + "-cover.jpg"
        return try sidecar(in: context.siblings, named: name)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        try await state(fileContext(path).file)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        downloadURLCache[path] = nil
        helper.invalidateCachedFile(path: path)
    }

    func replaceMetadataFile(at path: String, with file: URL, expected: EmbeddedMetadataRemoteFileState) async throws {
        _ = try await replaceMetadataFileReturningPath(at: path, with: file, expected: expected)
    }

    func replaceMetadataFileReturningPath(at path: String, with file: URL, expected: EmbeddedMetadataRemoteFileState) async throws -> String {
        let context = try await fileContext(path)
        guard try expected.matches(state(context.file)) else { throw EmbeddedMetadataWritebackSourceError.conflict }
        return try await publish(file, name: context.file.name, parent: context.parent, original: context.file).path
    }

    private static let uploadVisibilityDelays: [TimeInterval] = [0.5, 1.0, 2.0]
    private static let callbackRecoveryDelays: [TimeInterval] = [1.0, 2.0]
    private static let uploadRetryDelays: [TimeInterval] = [1.5, 3.0]
    private static let renameVisibilityDelays: [TimeInterval] = [0.5, 1.0]

    private func uploadPayload(_ endpoint: String, form: [URLQueryItem]? = nil, parent: String) async throws -> Data {
        let json = try await apiRequest(URL(string: Self.apiBase + endpoint)!, method: form == nil ? "GET" : "POST",
                                        form: form, replay: form == nil ? .idempotent : .never, missingPath: parent)
        guard let payload = json["data"] as? [String: Any] ?? (json["data"] as? [[String: Any]])?.first else {
            throw CloudDriveError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func upload(_ file: URL, fingerprint: Pan115FileUpload.Fingerprint, name: String, parent: String) async throws {
        try await Pan115FileUpload.upload(file: file, fingerprint: fingerprint, parent: parent, name: name) { form in
            try await self.uploadPayload("/upload/init", form: form, parent: parent)
        } credentials: {
            try await self.uploadPayload("/upload/get_token", parent: parent)
        } transfer: { [helper] request, body in
            let (data, response) = try await helper.sendOnce(request) { session, request in
                switch body {
                case .empty: return try await session.data(for: request, delegate: Pan115FileUpload.redirectDelegate)
                case .file(let url): return try await session.upload(for: request, fromFile: url, delegate: Pan115FileUpload.redirectDelegate)
                case .bytes(let bytes): return try await session.upload(for: request, from: bytes, delegate: Pan115FileUpload.redirectDelegate)
                }
            }
            guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
            return (data, http)
        }
    }

    private static func classifyUploadFailure(
        _ error: Error,
        parent: String
    ) -> (surfaced: Error, isRetryable: Bool, mayHaveCommitted: Bool, summary: String) {
        if let callbackError = error as? Pan115FileUpload.CallbackError {
            switch callbackError {
            case .tokenExpired:
                return (CloudDriveError.tokenExpired, false, false, "callback tokenExpired")
            case .rateLimited:
                return (HTTPResponseFailure(statusCode: 429, isRateLimited: true, isRetryable: true),
                        true, false, "callback rateLimited")
            case .notFound:
                return (CloudDriveError.fileNotFound(parent), false, false, "callback notFound")
            case .providerFailure(let code, let message):
                let surfaced = CloudDriveError.apiError(code, message.isEmpty ? "115 upload callback failed" : message)
                return (surfaced, callbackError.isRetryable, false,
                        "callback code=\(code) message=\(message.prefix(120))")
            case .unexpectedResponse(let statusCode, let ossCode, let bodyPreview):
                let surfaced: Error
                if statusCode != 200 {
                    surfaced = HTTPResponseFailure(statusCode: statusCode, isRetryable: true)
                } else if let ossCode, !ossCode.isEmpty {
                    surfaced = CloudDriveError.apiError(statusCode, ossCode)
                } else {
                    surfaced = CloudDriveError.invalidResponse
                }
                return (surfaced, true, true,
                        "callback unexpected status=\(statusCode) ossCode=\(ossCode ?? "-") body=\(bodyPreview.prefix(160))")
            }
        }
        if let failure = error as? HTTPResponseFailure {
            let retryable = failure.isRateLimitFailure
                || failure.isRetryable == true
                || CloudHTTPRetryPolicy.shouldRetry(statusCode: failure.statusCode)
            let mayHaveCommitted = failure.statusCode == 203 || failure.statusCode == 408 || failure.statusCode >= 500
            return (failure, retryable, mayHaveCommitted, "http status=\(failure.statusCode)")
        }
        if let urlError = error as? URLError {
            let transient = CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: urlError.errorCode)
                || urlError.code == .badServerResponse
            return (urlError, transient, transient, "urlError code=\(urlError.errorCode)")
        }
        if case CloudDriveError.apiError(let code, let message) = error {
            let lowered = message.lowercased()
            let transient = code == 408 || code == 425 || code == 429 || (500...599).contains(code)
                || ["繁忙", "超时", "重试", "稍后", "busy", "timeout", "try again", "temporarily"]
                    .contains { lowered.contains($0) }
            return (error, transient, false, "apiError code=\(code)")
        }
        return (error, false, false, String(describing: type(of: error)))
    }

    private static func uploadRetryDelay(for error: Error, defaultDelay: TimeInterval) -> TimeInterval {
        if let failure = error as? HTTPResponseFailure,
           let retryAfter = failure.retryAfter,
           retryAfter.isFinite, retryAfter > 0 {
            return min(retryAfter, 10)
        }
        return defaultDelay
    }

    private func sameOriginal(_ candidates: [RemoteFileItem], as original: RemoteFileItem?) throws {
        if let original {
            guard candidates.count == 1, let found = candidates.first, found.path == original.path,
                  !found.isDirectory, try state(found).matches(state(original)) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
        } else if !candidates.isEmpty {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
    }

    func replacementIndexKeys(from oldPath: String, to newPath: String) -> (old: String, new: String)? {
        guard let old = fileIDByPickCode[oldPath], let new = fileIDByPickCode[newPath] else { return nil }
        return (old, new)
    }

    private func renameFile(fileID: String, to newName: String, missingPath: String) async throws {
        _ = try await apiRequest(
            URL(string: Self.apiBase + "/ufile/update")!,
            method: "POST",
            form: [.init(name: "file_id", value: fileID), .init(name: "file_name", value: newName)],
            replay: .never,
            missingPath: missingPath
        )
    }

    private func confirmListing(
        at parent: String,
        allowLagRetry: Bool,
        matches: ([RemoteFileItem]) -> Bool
    ) async throws -> [RemoteFileItem] {
        let delays = allowLagRetry ? Self.renameVisibilityDelays : []
        var latest: [RemoteFileItem] = []
        for index in 0...delays.count {
            if index > 0 {
                try await sleep(delays[index - 1])
                try Task.checkCancellation()
            }
            latest = try await listFiles(at: parent)
            if matches(latest) { return latest }
        }
        return latest
    }

    private func recycle(_ item: RemoteFileItem, parent: String) async throws {
        guard item.parentPath == parent, let id = item.providerID else { throw CloudDriveError.invalidResponse }
        _ = try await apiRequest(URL(string: Self.apiBase + "/ufile/delete")!, method: "POST",
                                 form: [.init(name: "file_ids", value: id), .init(name: "parent_id", value: parent)],
                                 replay: .never, missingPath: item.path)
        await invalidateMetadataWritebackCache(for: item.path)
        // Preserve the immutable pick-code/file-ID pair until the library migrates its scan index.
        parentByPickCode[item.path] = nil
    }

    private func recycleLeftoverStages(
        in items: [RemoteFileItem],
        names: [String],
        excludingPath: String?,
        original: RemoteFileItem?,
        parent: String,
        fingerprint: Pan115FileUpload.Fingerprint
    ) async {
        let nameSet = Set(names)
        for item in items where !item.isDirectory && nameSet.contains(item.name) &&
            item.path != excludingPath && item.path != original?.path && item.providerID != original?.providerID &&
            item.size == fingerprint.size && item.revision?.uppercased() == fingerprint.sha1 {
            try? await recycle(item, parent: parent)
        }
    }

    private func rollbackPublish(
        parent: String,
        name: String,
        stage: RemoteFileItem,
        stageID: String,
        stageName: String,
        attemptedStageNames: [String],
        original: RemoteFileItem?,
        backupName: String,
        fingerprint: Pan115FileUpload.Fingerprint
    ) async -> RemoteFileItem? {
        func matchesBytes(_ item: RemoteFileItem) -> Bool {
            !item.isDirectory && item.size == fingerprint.size && item.revision?.uppercased() == fingerprint.sha1
        }
        guard let current = try? await listFiles(at: parent) else { return nil }
        let ownStage = current.first(where: {
            $0.providerID == stageID && $0.path == stage.path &&
            ($0.name == stageName || $0.name == name) && matchesBytes($0)
        })

        if let original, let originalID = original.providerID {
            let currentOriginal = current.first(where: { $0.providerID == originalID && $0.path == original.path })
            if let currentOriginal, currentOriginal.name == backupName {
                if let ownStage, ownStage.name == name {
                    // Free the target name before restoring the original (115 rejects duplicate names on rename).
                    try? await renameFile(fileID: stageID, to: stageName, missingPath: stage.path)
                }
                try? await renameFile(fileID: originalID, to: name, missingPath: original.path)
                guard let after = try? await listFiles(at: parent) else { return nil }
                if after.contains(where: { $0.providerID == originalID && $0.path == original.path && $0.name == name }) {
                    await recycleLeftoverStages(in: after, names: attemptedStageNames, excludingPath: nil,
                                                original: original, parent: parent, fingerprint: fingerprint)
                    return nil
                }
                // Keep the verified replacement reachable if the original could not be moved back.
                if let published = after.first(where: {
                    $0.providerID == stageID && $0.path == stage.path && $0.name == name && matchesBytes($0)
                }) {
                    return published
                }
                return nil
            }
            if currentOriginal?.name == name {
                await recycleLeftoverStages(in: current, names: attemptedStageNames, excludingPath: nil,
                                            original: original, parent: parent, fingerprint: fingerprint)
                if let ownStage, ownStage.name != name, !attemptedStageNames.contains(ownStage.name) {
                    try? await recycle(ownStage, parent: parent)
                }
            }
            return nil
        }

        await recycleLeftoverStages(in: current, names: attemptedStageNames, excludingPath: nil,
                                    original: nil, parent: parent, fingerprint: fingerprint)
        if let ownStage, !attemptedStageNames.contains(ownStage.name) {
            try? await recycle(ownStage, parent: parent)
        }
        return nil
    }

    private static let stageNamePrefix = "primuse-stage-"
    private static let backupNamePrefix = "primuse-old-"

    /// 115's `/open/ufile/update` silently keeps a file's original extension even when
    /// `file_name` specifies a different one. Temporary stage and backup names must preserve
    /// the target file's exact extension so renames into place and rollbacks keep the real suffix.
    static func temporarySiblingName(
        prefix: String,
        matching targetName: String,
        token: String = UUID().uuidString
    ) -> String {
        let ext = (targetName as NSString).pathExtension
        guard !ext.isEmpty else { return prefix + token }
        return prefix + token + "." + ext
    }

    static func isInternalStagingName(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        let uuidText: Substring
        if base.hasPrefix(stageNamePrefix) {
            uuidText = base.dropFirst(stageNamePrefix.count)
        } else if base.hasPrefix(backupNamePrefix) {
            uuidText = base.dropFirst(backupNamePrefix.count)
        } else {
            return false
        }
        return UUID(uuidString: String(uuidText)) != nil
    }

    /// 115's `/open/ufile/update` rejects renaming onto an existing sibling name with code 20004
    /// and silently ignores extension changes. Stage and verify the replacement under a unique
    /// same-extension name, move the original aside to a same-extension backup name, rename the
    /// replacement into place, and only then recycle the original.
    private func publish(_ file: URL, name: String, parent: String, original: RemoteFileItem?,
                         verifyBytes: Data? = nil) async throws -> RemoteFileItem {
        let fingerprint = try await Task.detached(priority: .utility) { try Pan115FileUpload.Fingerprint(file: file) }.value
        let backupName = Self.temporarySiblingName(prefix: Self.backupNamePrefix, matching: original?.name ?? name)
        func matchesBytes(_ item: RemoteFileItem) -> Bool {
            !item.isDirectory && item.size == fingerprint.size && item.revision?.uppercased() == fingerprint.sha1
        }
        func named(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
            items.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        func findStaged(in items: [RemoteFileItem], names: [String]) -> (item: RemoteFileItem, name: String)? {
            for candidate in names.reversed() {
                let matches = items.filter { $0.name == candidate && matchesBytes($0) }
                if matches.count == 1, let item = matches.first, let id = item.providerID,
                   !id.isEmpty, item.path != original?.path, id != original?.providerID {
                    return (item, candidate)
                }
            }
            return nil
        }

        try sameOriginal(named(try await listFiles(at: parent)), as: original)
        if let original, matchesBytes(original) {
            if let verifyBytes {
                let readback = try await fetchRange(path: original.path, offset: 0, length: Int64(verifyBytes.count))
                guard readback == verifyBytes else { throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed }
            }
            return original
        }

        // A lost/timed-out OSS callback (HTTP 203) or post-upload listing lag can follow an
        // upload that 115 still commits. Poll the unique stage name before retrying the upload.
        var attemptedStageNames: [String] = []
        var foundStage: (item: RemoteFileItem, name: String)?
        var listing: [RemoteFileItem] = []
        let maxUploadAttempts = 1 + Self.uploadRetryDelays.count

        uploadLoop: for attempt in 0..<maxUploadAttempts {
            try Task.checkCancellation()
            let candidateName = Self.temporarySiblingName(prefix: Self.stageNamePrefix, matching: name)
            attemptedStageNames.append(candidateName)
            var rawFailure: Error?
            do {
                try await upload(file, fingerprint: fingerprint, name: candidateName, parent: parent)
            } catch {
                if OperationCancellationPolicy.isCancellation(error) { throw error }
                rawFailure = error
            }

            let classified = rawFailure.map { Self.classifyUploadFailure($0, parent: parent) }
            let pollDelays: [TimeInterval]
            if classified == nil {
                pollDelays = Self.uploadVisibilityDelays
            } else if classified?.mayHaveCommitted == true {
                pollDelays = Self.callbackRecoveryDelays
            } else {
                pollDelays = []
            }

            for pollIndex in 0...pollDelays.count {
                if pollIndex > 0 {
                    try await sleep(pollDelays[pollIndex - 1])
                    try Task.checkCancellation()
                }
                listing = try await listFiles(at: parent)
                if let matched = findStaged(in: listing, names: attemptedStageNames) {
                    foundStage = matched
                    break uploadLoop
                }
            }

            if let classified {
                plog("⚠️ 115 upload attempt \(attempt + 1)/\(maxUploadAttempts) failed retryable=\(classified.isRetryable): \(classified.summary)")
                if classified.isRetryable, attempt < Self.uploadRetryDelays.count {
                    let delay = Self.uploadRetryDelay(for: classified.surfaced, defaultDelay: Self.uploadRetryDelays[attempt])
                    try await sleep(delay)
                    continue
                }
                throw classified.surfaced
            } else if attempt < Self.uploadRetryDelays.count {
                plog("⚠️ 115 uploaded stage missing from directory listing after polling; retrying upload \(attempt + 2)/\(maxUploadAttempts)")
                try await sleep(Self.uploadRetryDelays[attempt])
                continue
            } else {
                throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
        }

        guard let foundStage, let stageID = foundStage.item.providerID else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        let stage = foundStage.item
        let stageName = foundStage.name
        var retirementStarted = false
        do {
            if let verifyBytes {
                let readback = try await fetchRange(path: stage.path, offset: 0, length: Int64(verifyBytes.count))
                guard readback == verifyBytes else { throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed }
            }
            try sameOriginal(named(listing), as: original)
            try Task.checkCancellation()

            if let original {
                guard let originalID = original.providerID, !originalID.isEmpty else {
                    throw CloudDriveError.invalidResponse
                }
                var backupFailure: Error?
                do {
                    try await renameFile(fileID: originalID, to: backupName, missingPath: original.path)
                } catch { backupFailure = error }
                listing = try await confirmListing(at: parent, allowLagRetry: backupFailure == nil) { items in
                    items.contains(where: { $0.providerID == originalID && $0.path == original.path && $0.name == backupName })
                }
                guard listing.contains(where: {
                    $0.providerID == originalID && $0.path == original.path && $0.name == backupName
                }) else {
                    throw backupFailure ?? EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                }
                guard named(listing).isEmpty else {
                    throw EmbeddedMetadataWritebackSourceError.conflict
                }
            }

            try Task.checkCancellation()
            var renameFailure: Error?
            do {
                try await renameFile(fileID: stageID, to: name, missingPath: stage.path)
            } catch { renameFailure = error }
            listing = try await confirmListing(at: parent, allowLagRetry: renameFailure == nil) { items in
                items.contains(where: {
                    $0.providerID == stageID && $0.path == stage.path && $0.name == name && matchesBytes($0)
                })
            }
            guard let result = listing.first(where: {
                $0.providerID == stageID && $0.path == stage.path && $0.name == name && matchesBytes($0)
            }) else {
                throw renameFailure ?? EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
            guard named(listing).count == 1 else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }

            if let original {
                try Task.checkCancellation()
                retirementStarted = true
                var removalFailure: Error?
                do { try await recycle(original, parent: parent) }
                catch { removalFailure = error }
                let remaining: [RemoteFileItem]
                do {
                    remaining = try await listFiles(
                        at: parent,
                        confirmingPreviouslyObservedPaths: removalFailure == nil ? [result.path] : [result.path, original.path]
                    )
                } catch {
                    throw EmbeddedMetadataReplacementReadbackError(filePath: result.path, fileSize: result.size,
                                                                  detail: error.localizedDescription)
                }
                if remaining.contains(where: { $0.path == original.path }) {
                    retirementStarted = false
                    throw removalFailure ?? EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                }
                guard named(remaining).count == 1, remaining.contains(where: {
                    $0.path == result.path && $0.name == name && matchesBytes($0)
                }) else {
                    throw EmbeddedMetadataReplacementReadbackError(filePath: result.path, fileSize: result.size,
                        detail: EmbeddedMetadataWritebackSourceError.remoteVerificationFailed.localizedDescription)
                }
                if attemptedStageNames.count > 1 {
                    await recycleLeftoverStages(in: remaining, names: attemptedStageNames, excludingPath: result.path,
                                                original: original, parent: parent, fingerprint: fingerprint)
                }
            } else if attemptedStageNames.count > 1 {
                await recycleLeftoverStages(in: listing, names: attemptedStageNames, excludingPath: result.path,
                                            original: nil, parent: parent, fingerprint: fingerprint)
            }
            return result
        } catch {
            guard !(error is EmbeddedMetadataReplacementReadbackError) else { throw error }
            if !retirementStarted {
                let publishedReplacement = await Task { [self] () -> RemoteFileItem? in
                    await self.rollbackPublish(
                        parent: parent,
                        name: name,
                        stage: stage,
                        stageID: stageID,
                        stageName: stageName,
                        attemptedStageNames: attemptedStageNames,
                        original: original,
                        backupName: backupName,
                        fingerprint: fingerprint
                    )
                }.value
                if let publishedReplacement {
                    throw EmbeddedMetadataReplacementReadbackError(
                        filePath: publishedReplacement.path,
                        fileSize: publishedReplacement.size,
                        detail: error.localizedDescription
                    )
                }
            }
            throw error
        }
    }
}

extension U115Source {
    func lyricsSidecarTarget(for song: Song, request: LyricsDocumentRequest) async throws -> LyricsSidecarTarget {
        let (audio, parent, siblings) = try await fileContext(song.filePath)
        let base = (audio.name as NSString).deletingPathExtension
        func address(_ name: String) -> String { song.filePath + "/" + audio.name + "/" + name }
        if song.isCueTrack {
            guard let cue = try await LyricsSidecarTargetPolicy.cueTrackTarget(
                for: song, songBase: base, audioFileName: audio.name, containerPath: parent, items: siblings, using: self
            ) else { throw EmbeddedMetadataWritebackSourceError.conflict }
            // With opaque IDs even an album-wide lyric file looks like a per-track
            // reference. A shared document must never become the track's write target.
            if cue.separateWritePath == nil, cue.exists,
               (cue.fileName as NSString).deletingPathExtension.caseInsensitiveCompare(base) == .orderedSame {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            return LyricsSidecarTarget(targetPath: address(cue.fileName), fileName: cue.fileName, containerPath: parent,
                exists: cue.exists, existingPath: cue.existingPath, existingSize: cue.existingSize, songBaseName: cue.songBaseName,
                translationPath: cue.translationPath, translationFileName: cue.translationFileName, translationSize: cue.translationSize,
                separateWritePath: cue.separateWriteFileName.map(address), separateWriteFileName: cue.separateWriteFileName)
        }
        let existing = try LyricsSidecarTargetPolicy.uniqueExistingItem(baseName: base, in: siblings, request: request)
        let companion = LyricsSidecarTargetPolicy.translationTrackItem(forPrimary: existing, baseName: base, in: siblings)
        let name = existing?.name ?? base + ".lrc"
        return LyricsSidecarTarget(targetPath: address(name), fileName: name, containerPath: parent,
            exists: existing != nil, existingPath: existing?.path, existingSize: existing?.size, songBaseName: base,
            translationPath: companion?.path, translationFileName: companion?.name, translationSize: companion?.size,
            documents: LyricsSidecarTargetPolicy.documents(baseName: base, in: siblings))
    }

    private func sidecar(in siblings: [RemoteFileItem], named name: String) throws -> RemoteFileItem? {
        let matches = siblings.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1, matches.allSatisfy({ !$0.isDirectory && $0.name == name }) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        return matches.first
    }

    private func writeSidecar(_ data: Data, name: String, parent: String, original: RemoteFileItem?) async throws -> RemoteFileItem {
        guard !data.isEmpty else { throw CloudDriveError.invalidResponse }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-115-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        return try await publish(file, name: name, parent: parent, original: original, verifyBytes: data)
    }

    func writeLyricsSidecar(data: Data, target: LyricsSidecarTarget, priority: RangeFetchPriority) async throws -> LyricsSidecarWriteReceipt {
        let address = target.targetPath.split(separator: "/", maxSplits: 2)
        let fileExtension = (target.fileName as NSString).pathExtension.lowercased()
        guard address.count == 3, String(address[2]) == target.fileName, !target.fileName.contains("/"),
              LyricsSidecarSelectionPolicy.isWritableDocument(fileName: target.fileName)
                || (target.exists && PrimuseConstants.readableLyricsExtensions.contains(fileExtension)) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let context = try await fileContext(String(address[0]))
        let existing = try sidecar(in: context.siblings, named: target.fileName)
        guard context.file.name == String(address[1]), context.parent == target.containerPath, target.exists == (existing != nil),
              existing?.path == target.existingPath, target.existingSize == nil || existing?.size == target.existingSize else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let result = try await writeSidecar(data, name: target.fileName, parent: context.parent, original: existing)
        return .init(requestedTargetPath: target.targetPath, writtenPath: result.path, fileName: result.name,
                     containerPath: context.parent, remoteSize: result.size, readback: data)
    }

    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if let ext = PrimuseConstants.supportedLyricsExtensions.first(where: { path.hasSuffix("." + $0) }) {
            suffix = "." + ext
        } else { throw CloudDriveError.invalidResponse }
        let context = try await fileContext(String(path.dropLast(suffix.count)))
        let name = (context.file.name as NSString).deletingPathExtension + suffix
        _ = try await writeSidecar(data, name: name, parent: context.parent, original: sidecar(in: context.siblings, named: name))
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        // publish reads the actual uploaded pick_code before retiring any previous sidecar.
    }
}
