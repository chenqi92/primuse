import CryptoKit
import Foundation
import PrimuseKit

/// OAuth configuration for a cloud drive
struct CloudOAuthConfig: Sendable {
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
enum CloudDriveError: Error, LocalizedError {
    case notAuthenticated
    case tokenExpired
    case tokenRefreshFailed(String)
    case apiError(Int, String)
    case invalidResponse
    case fileNotFound(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Token expired"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .invalidResponse: return "Invalid response"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .rateLimited: return "Rate limited"
        }
    }
}

/// Shared HTTP + caching utilities for all cloud drive sources.
/// Each cloud source uses this as a helper instead of inheritance.
struct CloudDriveHelper: Sendable {
    let sourceID: String
    let tokenManager: CloudTokenManager

    var cacheDirectory: URL {
        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_cloud_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    init(sourceID: String) {
        self.sourceID = sourceID
        self.tokenManager = CloudTokenManager(sourceID: sourceID)
    }

    static func formURLEncodedBody(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
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

    // MARK: - Range request

    /// HTTP Range GET. `offset < 0` means "from end" — translated to `Range: bytes=-N`.
    /// Always returns bytes whose semantic position is `[offset, offset+length)` of
    /// the underlying file:
    /// - 206 Partial Content: response body is exactly that slice — pass through.
    /// - 200 OK: server ignored our Range header and sent the full file. We slice
    ///   the requested window ourselves so callers can trust offsets. Without this
    ///   correction, a seek-to-middle would write the start of the file into the
    ///   middle of our cache and corrupt `.partial` permanently.
    func rangeRequest(
        url: URL,
        offset: Int64,
        length: Int64,
        accessToken: String? = nil,
        userAgent: String? = nil,
        referer: String? = nil,
        timeoutSeconds: TimeInterval = 60,
        forceTCP: Bool = false
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
            } catch let TCPRangeFetcher.FetchError.http(code) {
                // 让上层的 401/403/410→刷新直链 逻辑照常生效。
                throw CloudDriveError.apiError(code, "Range request failed (TCP)")
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
        let (data, response) = try await Self.rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            // Server returned the full file. Translate "from end" offsets to
            // a positive index into the body, then slice to the requested window.
            let totalSize = Int64(data.count)
            let actualOffset: Int64 = offset < 0
                ? max(0, totalSize + offset)
                : offset
            guard actualOffset < totalSize else { return Data() }
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: actualOffset, length: length) else {
                return Data()
            }
            let upper = min(requestedEnd, totalSize)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
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
        do {
            return try await operation(initialToken)
        } catch {
            let rejected: Bool
            if case CloudDriveError.tokenExpired = error {
                rejected = true
            } else {
                rejected = isTokenRejection(error)
            }
            guard rejected else { throw error }
            plog("☁️ token rejected by server (\(error)); forcing refresh + retry sourceID=\(sourceID.prefix(8))…")
            // .ifMatches(被拒 token): 多路并发 401 共享一次刷新; 若 token 已被别的并发
            // 刷新换过则直接用新的, 不重复刷新(避免轮换型 refresh_token invalid_grant)。
            let fresh = try await tokenManager.refreshDeduped(.ifMatches(initialToken), refresh: refresh).accessToken
            return try await operation(fresh)
        }
    }

    func makeAuthorizedRequest(
        url: URL, method: String = "GET", body: Data? = nil,
        contentType: String? = nil, accessToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 429 { throw CloudDriveError.rateLimited }
        return (data, http)
    }

    // MARK: - Cache

    func cachedURL(for path: String) -> URL {
        // SHA256 哈希避免不同 path 经 '/' → '_' 替换后撞到同名缓存键、读到错误文件。
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        let name = ext.isEmpty ? hash : "\(hash).\(ext)"
        return cacheDirectory.appendingPathComponent(name)
    }

    func hasCached(path: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: path).path)
    }

    func cacheData(_ data: Data, for path: String) throws {
        try data.write(to: cachedURL(for: path))
    }

    // MARK: - Scan

    func scanAudioFiles(
        from path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem]
    ) -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, listFiles: listFiles, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 最多同时递归这么多个子目录。Baidu/Aliyun 的 listFiles 在 actor 里串行，
    /// 加上 100ms 节流，并发在网络层不会真正提速；但能让 listFiles 结果的 JSON
    /// 解析、子目录排队、文件 yield 的 CPU 工作叠在 I/O 等待之上。
    private static let scanConcurrency = 4

    private func scanDirectory(
        path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem],
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(path)

        // 找当前目录里的封面/歌词/MV 文件，作为 sidecar 候选
        let nonAudio = items.filter { !$0.isDirectory && !PrimuseConstants.supportedAudioExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        let folderCover = isGenericMusicDirectory(path) ? nil : findFolderCover(in: nonAudio)

        // 先把当前目录的音频文件 yield 出去，避免 ConnectorScanner 等子树扫完才开始处理
        var audioBasenames = Set<String>()
        for item in items where !item.isDirectory {
            let ext = (item.name as NSString).pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                let basename = (item.name as NSString).deletingPathExtension
                audioBasenames.insert(basename.lowercased())
                let cover = findSameNameCover(basename: basename, in: nonAudio) ?? folderCover
                let lyrics = findSameNameLyrics(basename: basename, in: nonAudio)
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
                    revision: item.revision
                )
                continuation.yield(withHints)
            }
        }

        // 独立 MV: 无同名音频的视频文件也 yield 成曲目, mvPath 指向自身
        // (Song.isStandaloneMusicVideo)。有同名音频的视频仍由上面的
        // sidecar 逻辑挂到那首歌上, 不重复成曲。
        for item in items where !item.isDirectory {
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard PrimuseConstants.supportedMusicVideoExtensions.contains(ext) else { continue }
            let basename = (item.name as NSString).deletingPathExtension
            guard audioBasenames.contains(basename.lowercased()) == false else { continue }
            let cover = findSameNameCover(basename: basename, in: nonAudio) ?? folderCover
            let lyrics = findSameNameLyrics(basename: basename, in: nonAudio)
            continuation.yield(RemoteFileItem(
                name: item.name,
                path: item.path,
                isDirectory: false,
                size: item.size,
                modifiedDate: item.modifiedDate,
                sidecarHints: SidecarHints(coverPath: cover, lyricsPath: lyrics, mvPath: item.path),
                revision: item.revision
            ))
        }

        let subdirs = items.filter { $0.isDirectory }
        guard !subdirs.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = subdirs.makeIterator()
            // 启动 N 个并发 worker
            for _ in 0..<min(Self.scanConcurrency, subdirs.count) {
                guard let next = iterator.next() else { break }
                group.addTask { [self] in
                    try await scanDirectory(path: next.path, listFiles: listFiles, continuation: continuation)
                }
            }
            // 每完成一个就投下一个，保持 N 路并发
            while try await group.next() != nil {
                guard let next = iterator.next() else { continue }
                group.addTask { [self] in
                    try await scanDirectory(path: next.path, listFiles: listFiles, continuation: continuation)
                }
            }
        }
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

    /// Find `cover.jpg`, `folder.jpg`, `album.jpg` etc. as a directory-wide fallback.
    private func findFolderCover(in candidates: [RemoteFileItem]) -> String? {
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                if let m = candidates.first(where: {
                    ($0.name as NSString).lowercased == "\(name).\(ext)"
                }) { return m.path }
            }
        }
        return nil
    }

    private func isGenericMusicDirectory(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["music", "音乐", "songs", "audio", "media", "downloads"].contains(name)
    }

    /// Find `{basename}.{lrc,...}` in the same dir.
    private func findSameNameLyrics(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedLyricsExtensions {
            if let m = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) { return m.path }
        }
        return nil
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
                    defer { handle.closeFile() }
                    while true {
                        let data = handle.readData(ofLength: 64 * 1024)
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
