import Foundation
import PrimuseKit

/// 光鸭云盘 Source —— 光鸭盘开放平台(openapi.guangyapan.com)。
///
/// 授权有两条路,拿到的 token 完全一样,之后走同一套业务接口:
///   · iPhone / iPad / Mac:Web OAuth 2.0 + PKCE(`www.guangyapan.com/oauth/`),
///     ASWebAuthenticationSession 打开授权页,授权后回调
///     `primuse://oauth/guangya/callback`,再用 code + code_verifier 换 token;
///   · Apple TV(以及手机上「用另一台设备授权」):Device Code —— 电视画二维码
///     或拉起光鸭盘 App(`gyp://auth?url=…`),轮询 `/v1/auth/token` 拿 token。
///
/// 业务接口除 `Authorization: Bearer` 外还要 `client_id` / `timestamp` / `sign`
/// 三个头(见 `GuangYaAPIProtocol.businessHeaders`),应答统一
/// `{code, msg, data}`;`code == 117` 表示 access_token 失效,刷新后重试。
///
/// 光鸭用「文件 ID」而非层级路径标识文件 —— `RemoteFileItem.path` / `Song.filePath`
/// 存的是 fileId 字符串,根目录在服务端没有 ID(列表接口不传 `parentId` 即为根),
/// 请求侧用空串代表它。文件夹层级只能靠 `RemoteFileItem.parentPath` 重建,那里
/// 填的是调用方用来定位本目录的标识,不是请求参数。
///
/// 开放平台目前只有读接口(列目录 / 详情 / 直链 / 用户信息),没有上传与删除,
/// 所以刮削的封面与歌词不回写光鸭,留在 Primuse 本地元数据缓存里
/// (`MusicSourceType.supportsSidecarWriting` / `supportsFileDeletion` 均为 false)。
actor GuangYaSource: MusicSourceConnector, OAuthCloudSource {
    let sourceID: String
    private let helper: CloudDriveHelper

    static let redirectURI = "\(CloudOAuthConfig.callbackScheme)://oauth/guangya/callback"

    /// fileId → (直链, 本地过期时间)。直链自带有效期(`urlDuration`,实测 6 小时),
    /// 官方明确要求不要长期缓存,这里按服务端给的时长打折缓存。
    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let maximumDownloadURLTTL: TimeInterval = 20 * 60
    /// 直链到期前这么久就当它已经过期,避免正在播的一段 Range 打到刚失效的链接。
    private static let downloadURLSafetyMargin: TimeInterval = 60

    /// 限频闸门。光鸭按 IP 限流:列表 5 次/秒,其余业务接口 2 次/秒。
    /// 扫描时 CloudDriveHelper 会并发递归 4 个子目录,不自我节流必然撞限频。
    private var fileListGateEnd = Date.distantPast
    private var businessGateEnd = Date.distantPast

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        _ = try await appConfig()
        _ = try await getToken()
    }

    func disconnect() async {}

    /// `/openapi/v1/user/get_user_info` 的 `userId` —— 跨 token 刷新、跨设备稳定,
    /// 用来把同一个光鸭账号下的多个挂载归并到一个 CloudAccount。
    func accountIdentifier() async throws -> String {
        guard let url = GuangYaAPIProtocol.userInfoURL else {
            throw CloudDriveError.invalidResponse
        }
        let data = try await authedGET(url, gate: .business)
        guard let info = GuangYaAPIProtocol.parseUserInfo(data) else {
            throw CloudDriveError.invalidResponse
        }
        return info.userID
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parentID = GuangYaAPIProtocol.isRootIdentifier(path) ? "" : path
        var items: [RemoteFileItem] = []
        var seenFileIDs = Set<String>()
        var page = 0
        var reportedTotal: Int?
        while true {
            guard let url = GuangYaAPIProtocol.fileListURL(
                parentID: parentID.isEmpty ? nil : parentID,
                page: page
            ) else {
                throw CloudDriveError.invalidResponse
            }
            let data = try await authedGET(url, gate: .fileList, notFoundPath: path)
            guard let listPage = GuangYaAPIProtocol.parseFileList(data) else {
                throw CloudDriveError.invalidResponse
            }
            let countBeforePage = items.count
            for entry in listPage.entries where seenFileIDs.insert(entry.fileID).inserted {
                items.append(RemoteFileItem(
                    name: entry.fileName,
                    path: entry.fileID,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modifiedDate: entry.createdAt,
                    // 开放平台不返回内容哈希 / etag,没有可信的版本标识。
                    revision: nil,
                    providerID: entry.fileID,
                    // 文件夹层级只能靠这个字段重建,填的必须是调用方用来定位
                    // 本目录的那个标识。根目录在光鸭侧没有 ID,若填成空串就和
                    // 扫描根记下的值("/" 或具体 fileId)对不上,整棵树会散成
                    // 一张平铺列表。
                    parentPath: path
                ))
            }
            if reportedTotal == nil, listPage.total > 0 { reportedTotal = listPage.total }
            // 本页没带来任何新条目 → 服务端在重复同一页,再翻下去也是原地踏步。
            guard items.count > countBeforePage else { break }
            page += 1
            guard GuangYaAPIProtocol.shouldRequestNextPage(
                receivedCount: listPage.entries.count,
                accumulatedCount: items.count,
                reportedTotal: reportedTotal,
                requestedPageSize: GuangYaAPIProtocol.defaultPageSize,
                nextPage: page
            ) else { break }
        }
        return items
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        return try await helper.downloadToCache(request: URLRequest(url: url), for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] directory in
            try await listFiles(at: directory)
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        do {
            return try await helper.rangeRequest(url: url, offset: offset, length: length)
        } catch CloudDriveError.apiError(let status, _) where [401, 403, 410].contains(status) {
            // 直链在有效期内也可能被服务端提前作废(换 IP / 会话失效)。
            // 丢掉缓存重新换一条再试一次,而不是把这次播放判死。
            invalidateDownloadURL(for: path)
            let refreshed = try await getDownloadURL(for: path)
            return try await helper.rangeRequest(url: refreshed, offset: offset, length: length)
        }
    }

    // MARK: - 直链

    private func getDownloadURL(for fileID: String) async throws -> URL {
        if let cached = downloadURLCache[fileID], cached.expiresAt > Date() { return cached.url }
        guard let endpoint = GuangYaAPIProtocol.downloadURL(fileID: fileID) else {
            throw CloudDriveError.invalidResponse
        }
        let data = try await authedGET(endpoint, gate: .business, notFoundPath: fileID)
        guard let ticket = GuangYaAPIProtocol.parseDownloadTicket(data) else {
            throw CloudDriveError.fileNotFound(fileID)
        }
        let serverTTL = ticket.duration - Self.downloadURLSafetyMargin
        let ttl = serverTTL > 0
            ? min(serverTTL, Self.maximumDownloadURLTTL)
            : Self.maximumDownloadURLTTL
        downloadURLCache[fileID] = (ticket.url, Date().addingTimeInterval(ttl))
        return ticket.url
    }

    private func invalidateDownloadURL(for fileID: String) {
        downloadURLCache.removeValue(forKey: fileID)
    }

    // MARK: - 限频

    private enum RequestGate {
        case fileList
        case business
    }

    /// 预约一个请求位:先把闸门往后推一格、再等到自己那一格。推格是同步的,
    /// 所以并发调用会各自排到不同的时间槽,不会一起挤在同一格上。
    private func reserveSlot(_ gate: RequestGate) -> TimeInterval {
        let now = Date()
        let interval: TimeInterval
        let start: Date
        switch gate {
        case .fileList:
            interval = GuangYaAPIProtocol.fileListMinimumInterval
            start = max(now, fileListGateEnd)
            fileListGateEnd = start.addingTimeInterval(interval)
        case .business:
            interval = GuangYaAPIProtocol.defaultMinimumInterval
            start = max(now, businessGateEnd)
            businessGateEnd = start.addingTimeInterval(interval)
        }
        return start.timeIntervalSince(now)
    }

    private func waitForSlot(_ gate: RequestGate) async throws {
        let delay = reserveSlot(gate)
        guard delay > 0 else { return }
        try await Task.sleep(for: .seconds(delay))
    }

    /// 撞到限频时把整条闸门往后推。只让当前这个请求退避没有用:同一条闸门上
    /// 排着的其他请求仍按原间隔发出,服务端看到的流量还是超限的。
    private func applyRateLimitCooldown(_ gate: RequestGate) {
        let resumeAt = Date().addingTimeInterval(GuangYaAPIProtocol.rateLimitCooldown)
        switch gate {
        case .fileList:
            fileListGateEnd = max(fileListGateEnd, resumeAt)
        case .business:
            businessGateEnd = max(businessGateEnd, resumeAt)
        }
    }

    // MARK: - 鉴权请求

    /// 发一个带签名头的业务 GET,校验 `{code}` 为 0,并把业务错误码翻成
    /// `CloudDriveError`。HTTP 401 或业务码 117 → withTokenRetry 刷新 token 重试一次。
    private func authedGET(
        _ url: URL,
        gate: RequestGate,
        notFoundPath: String? = nil
    ) async throws -> Data {
        let config = try await appConfig()
        let token = try await getToken()
        return try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken,
            isTokenRejection: Self.isAuthError
        ) { @Sendable accessToken in
            try await self.performGET(
                url,
                gate: gate,
                config: config,
                accessToken: accessToken,
                notFoundPath: notFoundPath
            )
        }
    }

    private func performGET(
        _ url: URL,
        gate: RequestGate,
        config: GuangYaAPIProtocol.AppConfig,
        accessToken: String,
        notFoundPath: String?
    ) async throws -> Data {
        var transientAttempt = 0
        var delay: TimeInterval = 0.75
        while true {
            try await waitForSlot(gate)
            // 签名头带 timestamp,每次重试都要重新生成,否则重试必然超出
            // 服务端允许的 300 秒时钟偏差。
            var request = URLRequest(url: url)
            for (field, value) in GuangYaAPIProtocol.businessHeaders(
                accessToken: accessToken,
                config: config
            ) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.timeoutInterval = 60

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSURLErrorDomain,
                      CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: nsError.code),
                      transientAttempt < 4 else { throw error }
                transientAttempt += 1
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                throw CloudDriveError.invalidResponse
            }
            if http.statusCode == 429 { applyRateLimitCooldown(gate) }
            if CloudHTTPRetryPolicy.shouldRetry(statusCode: http.statusCode), transientAttempt < 4 {
                transientAttempt += 1
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
                continue
            }
            if GuangYaAPIProtocol.indicatesInvalidToken(httpStatusCode: http.statusCode) {
                throw CloudDriveError.tokenExpired
            }
            if http.statusCode == 429 { throw CloudDriveError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(
                    http.statusCode,
                    String(data: data.prefix(512), encoding: .utf8) ?? ""
                )
            }
            guard let envelope = GuangYaAPIProtocol.parseEnvelope(data) else {
                throw CloudDriveError.invalidResponse
            }
            guard envelope.isSuccess else {
                // 101 是服务端自报的内部错误,厂商文档把它列为「安全请求可以
                // 有界重试」。业务接口全是 GET,重试没有副作用;不重试的话,
                // 整库扫描期间任何一次偶发 101 都会让那个目录连同整次扫描
                // 一起失败。
                if envelope.code == GuangYaAPIProtocol.ResultCode.internalError,
                   transientAttempt < 4 {
                    transientAttempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 8)
                    continue
                }
                throw Self.connectorError(for: envelope, notFoundPath: notFoundPath)
            }
            return data
        }
    }

    /// 业务错误码 → 连接器错误。签名无效(116)与 clientId 错误(120)是接入配置
    /// 问题,原样透出错误码,便于在日志里一眼认出是构建期凭据没注入。
    private static func connectorError(
        for envelope: GuangYaAPIProtocol.Envelope,
        notFoundPath: String?
    ) -> CloudDriveError {
        switch envelope.code {
        case GuangYaAPIProtocol.ResultCode.invalidAccessToken:
            return .tokenExpired
        case GuangYaAPIProtocol.ResultCode.accessDenied:
            return .permissionDenied(.fileRead)
        case GuangYaAPIProtocol.ResultCode.fileNotFound,
             GuangYaAPIProtocol.ResultCode.fileDeleted:
            return .fileNotFound(notFoundPath ?? "")
        default:
            return .apiError(envelope.code, envelope.message)
        }
    }

    private static func isAuthError(_ error: Error) -> Bool {
        if case CloudDriveError.tokenExpired = error { return true }
        if case CloudDriveError.apiError(let code, _) = error {
            return GuangYaAPIProtocol.indicatesInvalidToken(code: code)
        }
        return false
    }

    // MARK: - 接入方信息与 Token

    /// 平台分配的 client_id / project_id / sign_secret。project_id 与 sign_secret
    /// 只在构建期注入,用户即使自带 client_id 也沿用内置的那两项。
    private func appConfig() async throws -> GuangYaAPIProtocol.AppConfig {
        guard let bundled = GuangYaAPIProtocol.bundledAppConfig() else {
            throw CloudDriveError.apiError(
                GuangYaAPIProtocol.ResultCode.invalidSign,
                String(localized: "guangya_err_missing_app_config")
            )
        }
        guard let stored = await helper.tokenManager.getAppCredentials() else { return bundled }
        let clientID = stored.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, clientID != bundled.clientID else { return bundled }
        return GuangYaAPIProtocol.AppConfig(
            clientID: clientID,
            projectID: bundled.projectID,
            signSecret: bundled.signSecret
        )
    }

    private func getToken() async throws -> String {
        // proactive:本地标记过期才刷新,与 reactive(401 / 117)共享 CloudTokenManager
        // 的去重刷新,避免并发把同一个 refresh_token 刷两次。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    /// `POST /v1/auth/token`,JSON body,`grant_type=refresh_token`。
    /// nonisolated:只用 helper(Sendable)/静态常量/URLSession,不碰 actor 可变状态。
    private nonisolated func refreshToken(
        _ tokens: CloudTokenManager.Tokens
    ) async throws -> CloudTokenManager.Tokens {
        guard let refreshTokenValue = tokens.refreshToken, !refreshTokenValue.isEmpty else {
            throw CloudDriveError.tokenRefreshFailed("No refresh token")
        }
        let bundled = GuangYaAPIProtocol.bundledAppConfig()
        let stored = try? await helper.tokenManager.requireAppCredentials()
        let clientID = [stored?.clientId, bundled?.clientID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let clientID else { throw CloudDriveError.tokenRefreshFailed("No client ID") }

        var request = URLRequest(url: GuangYaAPIProtocol.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "x-client-id")
        if let projectID = bundled?.projectID {
            request.setValue(projectID, forHTTPHeaderField: "x-project-id")
        }
        request.httpBody = try SafeJSONSerialization.data(
            withJSONObject: GuangYaAPIProtocol.refreshTokenBody(
                clientID: clientID,
                refreshToken: refreshTokenValue
            )
        )
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw CloudDriveHelper.tokenRefreshFailure(
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                providerErrorCode: json["error"] as? String
            )
        }
        let expiresIn = (json["expires_in"] as? TimeInterval) ?? 1_800
        let rotated = (json["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            accessToken: accessToken,
            refreshToken: (rotated?.isEmpty == false) ? rotated : refreshTokenValue,
            expiresAt: Date().addingTimeInterval(expiresIn),
            tokenType: json["token_type"] as? String,
            extra: tokens.extra
        )
    }

    /// Web OAuth 2.0 + PKCE。授权页固定 `scope=user offline`(`offline` 决定能否
    /// 拿到 refresh_token),`code_challenge_method=S256`,回调收 `code` + `state`。
    ///
    /// 官方示例把 `state` 写成「就填 code_verifier」。这里仍用独立的一次性随机
    /// `state`:state 会随回调走一遍 URL,把 code_verifier 放进去等于让能截到
    /// 回调的一方同时拿到 code 和 verifier,PKCE 就白做了。state 的作用(关联
    /// 请求与回调、挡非法回调)用随机值同样成立。
    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .guangya,
            authURL: GuangYaAPIProtocol.webAuthorizeURL,
            tokenURL: GuangYaAPIProtocol.tokenURL.absoluteString,
            clientId: clientId,
            clientSecret: nil,
            scopes: GuangYaAPIProtocol.scopes,
            redirectURI: redirectURI,
            usesPKCE: true
        )
    }
}
