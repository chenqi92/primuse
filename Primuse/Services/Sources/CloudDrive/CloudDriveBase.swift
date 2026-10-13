import CryptoKit
import Foundation
import PrimuseKit

/// OAuth configuration for a cloud drive
struct CloudOAuthConfig: Sendable {
    let provider: MusicSourceType
    let authURL: String
    let tokenURL: String
    let clientId: String
    let clientSecret: String?
    let scopes: [String]
    let redirectURI: String
    let scopeSeparator: String
    let usesPKCE: Bool
    /// 当 redirectURI 是 https 中转页时，必须显式指定真正回到 App 的自定义 scheme
    /// （ASWebAuthenticationSession 要监听这个 scheme 才能拦截到中转页 JS 跳回来的那一下）。
    /// 如果为 nil，则自动从 redirectURI 派生。
    let explicitCallbackScheme: String?

    static let callbackScheme = "primuse"

    var callbackURLScheme: String {
        explicitCallbackScheme
            ?? URLComponents(string: redirectURI)?.scheme
            ?? Self.callbackScheme
    }

    init(
        provider: MusicSourceType,
        authURL: String,
        tokenURL: String,
        clientId: String,
        clientSecret: String?,
        scopes: [String],
        redirectURI: String,
        scopeSeparator: String = " ",
        usesPKCE: Bool = true,
        explicitCallbackScheme: String? = nil
    ) {
        self.provider = provider
        self.authURL = authURL
        self.tokenURL = tokenURL
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.scopeSeparator = scopeSeparator
        self.usesPKCE = usesPKCE
        self.explicitCallbackScheme = explicitCallbackScheme
    }
}

/// Common errors for cloud drive operations
enum CloudDrivePermission: Sendable {
    case accountAccess
    case fileRead
    case fileWrite
}

enum CloudDriveError: Error, LocalizedError {
    case notAuthenticated
    case credentialTemporarilyUnavailable(Int32)
    case credentialReadFailed(Int32)
    case tokenExpired
    case tokenRefreshFailed(String)
    case tokenPersistenceFailed
    case permissionDenied(CloudDrivePermission)
    case apiError(Int, String)
    case invalidResponse
    case fileNotFound(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "error_not_authenticated")
        case .credentialTemporarilyUnavailable(let status):
            return String(
                format: String(localized: "error_credential_temporarily_unavailable %@"),
                String(status)
            )
        case .credentialReadFailed(let status):
            return String(
                format: String(localized: "error_credential_read_failed %@"),
                String(status)
            )
        case .tokenExpired:
            return String(localized: "error_token_expired")
        case .tokenRefreshFailed(let message):
            return String(format: String(localized: "error_token_refresh_failed %@"), message)
        case .tokenPersistenceFailed:
            return String(localized: "error_token_persistence_failed")
        case .permissionDenied(let permission):
            switch permission {
            case .accountAccess:
                return String(localized: "cloud_permission_account_access")
            case .fileRead:
                return String(localized: "cloud_permission_file_read")
            case .fileWrite:
                return String(localized: "cloud_permission_file_write")
            }
        case .apiError(let code, let message):
            return String(
                format: String(localized: "error_api %@ %@"),
                String(code),
                message
            )
        case .invalidResponse:
            return String(localized: "error_invalid_response")
        case .fileNotFound(let path):
            return String(format: String(localized: "error_file_not_found %@"), path)
        case .rateLimited:
            return String(localized: "error_rate_limited")
        }
    }
}

/// Quotas outlive connector instances and token rotations. Mounts of a known
/// cloud account share API/CDN quotas; unknown accounts remain source-scoped.
/// GuangYa's documented IP quota is shared across accounts, per interface class.
final class CloudRequestScheduler: @unchecked Sendable {
    static let shared = CloudRequestScheduler()
    private let lock = NSLock()
    private var accounts: [String: String] = [:]
    private var executors: [String: RequestExecutor] = [:]
    private let timing: RequestExecutor.Timing
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    init(timing: RequestExecutor.Timing = .init(),
         jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { .random(in: 0...$0) }) {
        self.timing = timing
        self.jitter = jitter
    }

    func register(sourceID: String, accountID: String?) {
        lock.withLock { accounts[sourceID] = accountID.map { "account:" + $0 } }
    }

    func executor(sourceID: String, url: URL) -> RequestExecutor {
        lock.withLock {
            let host = (url.host ?? "").lowercased() + ":\(url.port ?? (url.scheme == "https" ? 443 : 80))"
            var owner = accounts[sourceID] ?? "source:\(sourceID)"
            var endpoint = "requests"
            var interval: TimeInterval = 0
            if url.host == "openapi.guangyapan.com" {
                owner = "guangya-ip"
                let isList = url.path.hasSuffix(GuangYaAPIProtocol.fileListPath)
                endpoint = isList ? "file-list" : "business"
                interval = isList ? GuangYaAPIProtocol.fileListMinimumInterval : GuangYaAPIProtocol.defaultMinimumInterval
            } else if url.host == "pan.baidu.com" {
                interval = 0.1
            }
            let key = "\(owner)|\(host)|\(endpoint)"
            if let executor = executors[key] { return executor }
            let executor = RequestExecutor(policy: .init(
                minimumInterval: interval, maximumConcurrentRequests: 6,
                maximumAttempts: 5, maximumRetryWait: 8,
                timeout: 3600, rateLimitStatusCodes: [429], defaultCooldown: 2
            ), timing: timing, jitter: jitter)
            executors[key] = executor
            return executor
        }
    }
}

/// Installed by withTokenRetry so HTTP and provider-envelope rejections recover
/// inside the executor's existing budget, rather than starting another retry loop.
private actor CloudRequestAuthorization {
    @TaskLocal static var current: CloudRequestAuthorization?
    nonisolated let sourceID: String
    private(set) var token: String
    private var refreshed = false
    private let refresh: @Sendable (String) async throws -> String

    init(sourceID: String, token: String, refresh: @escaping @Sendable (String) async throws -> String) {
        self.sourceID = sourceID
        self.token = token
        self.refresh = refresh
    }

    func recover(_ error: Error) async throws -> Bool {
        guard case CloudDriveError.tokenExpired = error else { return false }
        return try await refreshOnce()
    }

    func exhaustRecovery() { refreshed = true }

    func refreshOnce() async throws -> Bool {
        try Task.checkCancellation()
        guard !refreshed else { return false }
        refreshed = true
        // A refresh is shared by other requests and must finish/persist even if
        // this caller is cancelled. Cancel only this wait, not the shared task.
        let race = CancellableResultRace<String>()
        let rejected = token
        let refresh = refresh
        Task {
            do { race.resolve(.success(try await refresh(rejected))) }
            catch { race.resolve(.failure(error)) }
        }
        token = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.install($0) }
        } onCancel: { race.cancel() }
        return true
    }
}

/// Shared HTTP + caching utilities for all cloud drive sources.
/// Each cloud source uses this as a helper instead of inheritance.
struct CloudDriveHelper: Sendable {
    let sourceID: String
    let tokenManager: CloudTokenManager
    private let cacheNamespace: String
    private let apiSession: URLSession
    private let requests: CloudRequestScheduler
    private let validateResponse: @Sendable (Data, HTTPURLResponse) throws -> Void

    var cacheDirectory: URL {
        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_cloud_cache/\(sourceID)")
            .appendingPathComponent(cacheNamespace)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    init(
        sourceID: String, requests: CloudRequestScheduler = .shared, session: URLSession = .shared,
        validateResponse: @escaping @Sendable (Data, HTTPURLResponse) throws -> Void = { _, _ in }
    ) {
        self.apiSession = session
        self.requests = requests
        self.validateResponse = validateResponse
        self.sourceID = sourceID
        self.tokenManager = CloudTokenManager(sourceID: sourceID)
        self.cacheNamespace = MusicSourceSecurityRevision.cacheNamespace(for: sourceID)
    }

    static func formURLEncodedBody(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return FormSafeQueryURLBuilder.percentEncodedQuery(from: components)?.data(using: .utf8)
    }

    /// Parses an OAuth refresh response and preserves the distinction between
    /// temporary provider failures and permanently invalid credentials.
    static func tokenRefreshJSON(
        data: Data,
        response: URLResponse
    ) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let providerError = json["error"] as? String

        if !(200...299).contains(http.statusCode) || providerError != nil {
            throw tokenRefreshFailure(
                statusCode: http.statusCode,
                providerErrorCode: providerError
            )
        }
        return json
    }

    static func tokenRefreshFailure(
        statusCode: Int?,
        providerErrorCode: String? = nil
    ) -> CloudDriveError {
        switch CloudTokenRefreshPolicy.disposition(
            statusCode: statusCode,
            providerErrorCode: providerErrorCode
        ) {
        case .transient:
            return .apiError(statusCode ?? 503, "Token refresh temporarily unavailable")
        case .permanent:
            if let reason = providerErrorCode?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                return .tokenRefreshFailed(reason)
            }
            return .tokenRefreshFailed("HTTP \(statusCode ?? 0)")
        }
    }

    /// 云盘 Range 专用 session。不能用 `URLSession.shared`: 它的
    /// `httpMaximumConnectionsPerHost` 继承平台默认值 —— iOS=4 而 macOS=6。
    /// 起播瞬间 CloudPlaybackSource 的 prefetchAhead(4)+user fetch=5 路 Range
    /// 同打同一个 OneDrive CDN host, iOS 只有 4 条连接时第 5 路排队; 叠加冷大
    /// 文件首 chunk 被服务端 hydration 长占连接, 后续 chunk head-of-line block
    /// 集体撞 30s 超时 —— 这正是"大文件播 2 秒断、macOS(6 连接)却正常"的根因。
    /// 显式设 6 把 iOS 对齐到 macOS。
    static let rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(
            configuration: config,
            delegate: CloudRangeConnectionMetrics(),
            delegateQueue: nil
        )
    }()

    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    // MARK: - Range request

    /// HTTP Range GET. `offset < 0` means "from end" — translated to `Range: bytes=-N`.
    /// Always returns bytes whose semantic position is `[offset, offset+length)` of
    /// the underlying file:
    /// - 206 Partial Content: response body is exactly that slice — pass through.
    /// - 200 OK: server ignored our Range header. Abort before buffering the full
    ///   file; the playback layer will fall back to its streamed full download.
    func rangeRequest(
        url: URL,
        offset: Int64,
        length: Int64,
        accessToken: String? = nil,
        userAgent: String? = nil,
        referer: String? = nil,
        timeoutSeconds: TimeInterval = 60,
        forceTCP: Bool = false, session: URLSession = Self.rangeSession
    ) async throws -> Data {
        // Range callers already own chunk/short-read recovery. This executor
        // admits one transfer and shares its cooldown without nesting retries.
        let executor = requests.executor(sourceID: sourceID, url: url)
        return try await executor.execute(timeout: timeoutSeconds, operation: {
            try await self.performRangeRequest(
                url: url, offset: offset, length: length, accessToken: accessToken,
                userAgent: userAgent, referer: referer, timeoutSeconds: timeoutSeconds,
                forceTCP: forceTCP, session: session
            )
        })
    }

    private func performRangeRequest(
        url: URL, offset: Int64, length: Int64, accessToken: String?,
        userAgent: String?, referer: String?, timeoutSeconds: TimeInterval,
        forceTCP: Bool, session: URLSession
    ) async throws -> Data {
        // forceTCP：用 NWConnection 走 TCP+HTTP/1.1 绕开 HTTP/3(QUIC)。OneDrive CDN
        // 的 QUIC 路径在 iOS 上慢 20~30 倍(实测 ~100KB/s vs macOS h2 ~2MB/s)，而
        // URLSession 无法可靠禁用 QUIC。只对预授权直链(无需 Bearer/Referer)生效。
        if forceTCP, accessToken == nil {
            let t0 = Date()
            do {
                let data = try await TCPRangeFetcher.fetch(
                    url: url, offset: offset, length: length,
                    userAgent: userAgent, timeoutSeconds: timeoutSeconds
                )
                plog(String(format: "🔌 TCP range host=%@ off=%lld got=%dKB in %.2fs (h1.1, no-QUIC)",
                            url.host ?? "?", offset, data.count / 1024, Date().timeIntervalSince(t0)))
                return data
            } catch let TCPRangeFetcher.FetchError.http(failure) {
                if failure.retryAfter != nil || CloudHTTPRetryPolicy.shouldRetry(statusCode: failure.statusCode) {
                    throw failure
                }
                throw CloudDriveError.apiError(failure.statusCode, "Range request failed (TCP)")
            }
        }
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userAgent {
            // Some providers (notably Baidu) refuse / throttle dlink fetches
            // unless the request looks like it's coming from their first-party
            // client. URLSession preserves custom headers across 302s, so this
            // also applies to the redirected CDN URL.
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        request.timeoutInterval = timeoutSeconds
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
        defer { bytes.task.cancel() }
        try Self.checkHTTPFailure(data: Data(), response: http)
        switch http.statusCode {
        case 206:
            var data = Data()
            data.reserveCapacity(Int(min(length, 4 * 1024 * 1024)))
            for try await byte in bytes {
                if Int64(data.count) >= length { break }
                data.append(byte)
            }
            return data
        case 200:
            throw CloudDriveError.apiError(200, "Server ignored byte-range request")
        default:
            // Surface the status code so the caller can decide whether
            // it's recoverable (401/403/410 → token/dlink refresh) and
            // so the log shows which provider error triggered a
            // mid-stream playback failure.
            plog("⚠️ rangeRequest HTTP \(http.statusCode) for \(url.host ?? "?") path=\(url.path.suffix(60))")
            throw CloudDriveError.apiError(http.statusCode, "Range request failed")
        }
    }

    // MARK: - Authorized HTTP request

    /// Force-refresh the stored token regardless of the locally-tracked
    /// `expiresAt`, persist it, and return the fresh access token.
    ///
    /// `getToken()` in each source only refreshes when the *local* `expiresAt`
    /// says the token is expired (with a 5-min margin). If the server revokes a
    /// token early (password change, security policy) or the clock drifts, every
    /// call inside that "locally-valid" window keeps failing 401/111 with no
    /// self-healing. This lets a source recover by refreshing on demand and
    /// retrying. `refresh` does the provider-specific token exchange; on failure
    /// it should throw (typically `CloudDriveError.tokenRefreshFailed`) so the
    /// caller can surface a re-authorization prompt.
    func forceRefreshToken(
        refresh: @Sendable @escaping (CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens
    ) async throws -> String {
        // 走 tokenManager 的去重刷新, 与 getToken 的 proactive 路径共享同一 in-flight 任务。
        try await tokenManager.refreshDeduped(.force, refresh: refresh).accessToken
    }

    /// Run `operation`; if it fails because the server rejected the token
    /// (HTTP 401 → `CloudDriveError.tokenExpired`, or any error for which
    /// `isTokenRejection` returns true, e.g. Baidu errno 111/-6), force-refresh
    /// the token (ignoring local `expiresAt`) and retry the operation exactly
    /// once. If the refresh itself fails, the refresh error is thrown so the
    /// user can be guided to re-authorize.
    ///
    /// `operation` receives the access token to use for that attempt: the
    /// originally-obtained token on the first try, the freshly-refreshed token
    /// on the retry.
    func withTokenRetry<T>(
        initialToken: String,
        refresh: @Sendable @escaping (CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens,
        isTokenRejection: (Error) -> Bool = { _ in false },
        operation: (String) async throws -> T
    ) async throws -> T {
        let authorization = CloudRequestAuthorization(sourceID: sourceID, token: initialToken) { rejected in
            try await tokenManager.refreshDeduped(.ifMatches(rejected), refresh: refresh).accessToken
        }
        return try await CloudRequestAuthorization.$current.withValue(authorization) {
            do {
                return try await operation(initialToken)
            } catch {
                let rejected: Bool
                if case CloudDriveError.tokenExpired = error { rejected = true }
                else { rejected = isTokenRejection(error) }
                guard rejected, try await authorization.refreshOnce() else { throw error }
                return try await operation(authorization.token)
            }
        }
    }

    /// One complete HTTP operation. Build signed headers/tokens at send time;
    /// validate provider envelopes inside the same retry and recovery budget.
    func dataRequest(
        url: URL, replay: RequestExecutor.Replay = .never, session: URLSession? = nil,
        timeout: TimeInterval = 60,
        validate: @escaping @Sendable (Data, HTTPURLResponse) async throws -> Void = { _, _ in },
        request: @escaping @Sendable (String?) async throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let session = session ?? apiSession
        let executor = requests.executor(sourceID: sourceID, url: url)
        let current = CloudRequestAuthorization.current
        let authorization = current?.sourceID == sourceID ? current : nil
        do {
            return try await executor.execute(replay: replay, timeout: timeout, recover: { error in
                try await authorization?.recover(error) ?? false
            }, operation: {
                let req = try await request(authorization?.token)
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
                try self.validateResponse(data, http)
                try Self.checkHTTPFailure(data: data, response: http)
                try await validate(data, http)
                if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
                return (data, http)
            })
        } catch CloudDriveError.tokenExpired {
            // In particular, a 401 on the final allowed attempt must not escape
            // to withTokenRetry and start a fresh HTTP attempt/deadline budget.
            await authorization?.exhaustRecovery()
            throw CloudDriveError.tokenExpired
        }
    }

    /// Non-retryable statuses remain available to adapters (404, write conflicts,
    /// ordinary 403, etc.). Temporary failures retain their status, body and delay.
    static func checkHTTPFailure(data: Data, response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        let delay = HTTPResponseFailure.retryDelay(from: response)
        if delay != nil || CloudHTTPRetryPolicy.shouldRetry(statusCode: response.statusCode) {
            throw HTTPResponseFailure(
                statusCode: response.statusCode, body: data, retryAfter: delay,
                isRetryable: CloudHTTPRetryPolicy.shouldRetry(statusCode: response.statusCode)
            )
        }
    }

    func makeAuthorizedRequest(
        url: URL, method: String = "GET", body: Data? = nil,
        contentType: String? = nil, accessToken: String,
        isIdempotent: Bool? = nil, session: URLSession? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let mayRetry = isIdempotent ?? ["GET", "HEAD"].contains(method.uppercased())
        return try await dataRequest(url: url, replay: mayRetry ? .idempotent : .never, session: session) { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token ?? accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            request.timeoutInterval = 60
            return request
        }
    }

    // MARK: - Cache

    nonisolated static func cacheFileName(for path: String) -> String {
        // SHA256 哈希避免不同 path 经 '/' → '_' 替换后撞到同名缓存键、读到错误文件。
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    func cachedURL(for path: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheFileName(for: path))
    }

    func hasCached(path: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: path).path)
    }

    func invalidateCachedFile(path: String) {
        try? FileManager.default.removeItem(at: cachedURL(for: path))
    }

    /// Streams a complete remote file to URLSession's temporary file and only
    /// publishes the cache entry after a successful HTTP response.
    func downloadToCache(request: URLRequest, for path: String, session: URLSession = Self.downloadSession) async throws -> URL {
        let destination = cachedURL(for: path)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard let url = request.url else { throw CloudDriveError.invalidResponse }
        let executor = requests.executor(sourceID: sourceID, url: url)
        // Keep streaming to a temporary file; never buffer a full download in Data.
        return try await executor.execute(operation: {
            let (temporaryURL, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
            try Self.checkHTTPFailure(data: Data(), response: http)
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
                throw CloudDriveError.apiError(http.statusCode, "Download failed")
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
            return destination
        })
    }

    // MARK: - Scan

    func scanAudioFiles(
        from path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem]
    ) -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // One task group owns the entire traversal budget, including nested folders.
                    try await withThrowingTaskGroup(of: [String].self) { group in
                        var pending = [path]
                        var active = 0
                        while !pending.isEmpty || active > 0 {
                            try Task.checkCancellation()
                            while active < Self.scanConcurrency, let next = pending.popLast() {
                                active += 1
                                group.addTask {
                                    try await scanDirectory(
                                        path: next, listFiles: listFiles, continuation: continuation
                                    )
                                }
                            }
                            if let children = try await group.next() {
                                active -= 1
                                // 倒序入栈，popLast 才会按目录原来的顺序进入子文件夹。
                                pending.append(contentsOf: children.reversed())
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// Maximum in-flight directory listings across the complete scan.
    private static let scanConcurrency = 4

    private func scanDirectory(
        path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem],
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws -> [String] {
        try Task.checkCancellation()
        let items = try await listFiles(path)

        // 找当前目录里的封面/歌词/MV 文件，作为 sidecar 候选
        let nonAudio = items.filter {
            guard !$0.isDirectory else { return false }
            let ext = ($0.name as NSString).pathExtension.lowercased()
            return !PrimuseConstants.supportedAudioExtensions.contains(ext)
                && !PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext)
        }
        // 文件夹名按路径推,和别处的目录索引(`SidecarDirectoryIndex`)同一个算法:按 ID 寻址的
        // 网盘路径里没有名字,两边都不认「和文件夹同名的图片」,增量对账时选出的封面才不会变。
        let folderName = path.contains("/") ? (path as NSString).lastPathComponent : nil
        let folderCover = isGenericMusicDirectory(path)
            ? nil
            : findFolderCover(in: nonAudio, folderName: folderName)
        // 歌词还多一档 `<曲名>.<语言>.vtt` 的命名(yt-dlp、媒体服务器都这么写),
        // 判定要同时看目录里有没有同名音频, 所以直接用共享索引: 每个目录建一次,
        // 每首歌只查表, 不再逐曲扫整份清单。
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)

        // 先把当前目录的音频文件 yield 出去，避免 ConnectorScanner 等子树扫完才开始处理
        var audioBasenames = Set<String>()
        for item in items where !item.isDirectory {
            try Task.checkCancellation()
            let ext = (item.name as NSString).pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(ext)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                let basename = (item.name as NSString).deletingPathExtension
                audioBasenames.insert(basename.lowercased())
                let cover = findSameNameCover(basename: basename, in: nonAudio) ?? folderCover
                let lyrics = sidecarIndex.sameNameLyrics(basename: basename)?.path
                let mvPath = findSameNameMusicVideo(basename: basename, in: nonAudio)
                let withHints = RemoteFileItem(
                    name: item.name,
                    path: item.path,
                    isDirectory: false,
                    size: item.size,
                    modifiedDate: item.modifiedDate,
                    sidecarHints: (cover != nil || lyrics != nil || mvPath != nil)
                        ? SidecarHints(coverPath: cover, lyricsPath: lyrics, mvPath: mvPath)
                        : nil,
                    // Preserve provider revision (md5/etag/content_hash)
                    // through the sidecar-decoration step. Without this,
                    // each cloud connector's listFiles would surface a
                    // revision but ConnectorScanner — which consumes
                    // scanAudioFiles — would only ever see nil, defeating
                    // same-size overwrite detection on every cloud drive.
                    revision: item.revision,
                    providerID: item.providerID,
                    parentPath: item.parentPath
                )
                continuation.yield(withHints)
            }
        }

        // 独立 MV: 无同名音频的视频文件也 yield 成曲目, mvPath 指向自身
        // (Song.isStandaloneMusicVideo)。有同名音频的视频仍由上面的
        // sidecar 逻辑挂到那首歌上, 不重复成曲。
        for item in items where !item.isDirectory {
            try Task.checkCancellation()
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard PrimuseConstants.supportedMusicVideoExtensions.contains(ext) else { continue }
            let basename = (item.name as NSString).deletingPathExtension
            guard audioBasenames.contains(basename.lowercased()) == false else { continue }
            let cover = findSameNameCover(basename: basename, in: nonAudio) ?? folderCover
            let lyrics = sidecarIndex.sameNameLyrics(basename: basename)?.path
            continuation.yield(RemoteFileItem(
                name: item.name,
                path: item.path,
                isDirectory: false,
                size: item.size,
                modifiedDate: item.modifiedDate,
                sidecarHints: SidecarHints(coverPath: cover, lyricsPath: lyrics, mvPath: item.path),
                revision: item.revision,
                providerID: item.providerID,
                parentPath: item.parentPath
            ))
        }

        return items.filter(\.isDirectory).map(\.path)
    }

    // MARK: - Sidecar lookup helpers

    /// Find `{basename}.{jpg,png,...}` or `{basename}-cover.{...}` in the same dir.
    private func findSameNameCover(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedCoverExtensions {
            if let m = candidates.first(where: {
                let n = ($0.name as NSString).lowercased
                return n == "\(baseLower).\(ext)" || n == "\(baseLower)-cover.\(ext)"
            }) { return m.path }
        }
        return nil
    }

    /// Find `cover.jpg`, `folder.jpg`, `album.jpg` etc. as a directory-wide fallback,
    /// then a picture named after the folder itself (`FolderCoverNamePolicy`).
    private func findFolderCover(in candidates: [RemoteFileItem], folderName: String?) -> String? {
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                if let m = candidates.first(where: {
                    ($0.name as NSString).lowercased == "\(name).\(ext)"
                }) { return m.path }
            }
        }
        guard let named = FolderCoverNamePolicy.namedCover(
            among: candidates.map(\.name),
            folderName: folderName
        ) else { return nil }
        return candidates.first { $0.name == named }?.path
    }

    private func isGenericMusicDirectory(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["music", "音乐", "songs", "audio", "media", "downloads"].contains(name)
    }

    /// Find `{basename}.{mp4,m4v,mov}` in the same dir.
    private func findSameNameMusicVideo(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedMusicVideoExtensions {
            if let m = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) { return m.path }
        }
        return nil
    }

    // MARK: - Stream from cache

    func streamFromCache(path: String) -> AsyncThrowingStream<Data, Error> {
        let url = cachedURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while true {
                        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// 记录每个云盘 Range 请求实际复用了哪条连接、协商出什么协议。用来证实/证伪
/// "iOS 把 5 路 Range 多路复用坍缩到单条 TCP(HTTP/2 connection coalescing)"
/// —— 若真坍缩成单连接, `httpMaximumConnectionsPerHost=6` 形同虚设, 需要改走
/// 降并发方案。只对 OneDrive/SharePoint host 打日志, 避免刷屏。
final class CloudRangeConnectionMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let host = task.originalRequest?.url?.host ?? "?"
        guard host.contains("microsoft") || host.contains("sharepoint")
                || host.contains("1drv") || host.contains("onedrive") else { return }
        guard let t = metrics.transactionMetrics.last else { return }
        let dur = metrics.taskInterval.duration
        plog(String(format: "🔌 range conn host=%@ reused=%@ proto=%@ dur=%.2fs",
                    host,
                    t.isReusedConnection ? "Y" : "N",
                    t.networkProtocolName ?? "?",
                    dur))
    }
}
