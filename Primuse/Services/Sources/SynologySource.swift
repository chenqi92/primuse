import Foundation
import PrimuseKit

actor SynologySource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    nonisolated let directoryListingConcurrency = 4

    private let api: SynologyAPI
    private let username: String
    private let rememberDevice: Bool
    private let deviceId: String?
    private let alternateTLSValidationHostname: String?
    private let alternateTLSValidationEndpoint: NetworkEndpointIdentity?
    private let cacheDirectory: URL
    /// In-flight login dedupe. 多个 connect() 同时被预取/解码路径调起时,
    /// 让首个发起的登录跑,后面的全部 await 同一个 Task。否则 actor 重入
    /// 会让 N 路并发各自打一发 login,触发 DSM 的「自动封禁」(实测短时
    /// 60+ 次登录被 407 拒, 之后即便密码对也被回 400 用户名/密码错误)。
    private var loginTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Error>?
    /// 读标签时从 206 的 `Content-Range` 记下的文件大小: 尾部读取据此换成正向区间,
    /// 不依赖 DSM 认不认 `bytes=-N`。只在这个连接器存活期间有效。
    private var metadataFileSizes: [String: Int64] = [:]
    /// 这台服务器(或者中间的反向代理)读标签时回过 200 整个文件: 之后尾部与离开头太远的
    /// 读取不再发请求。
    private var metadataRangeIgnored = false

    /// 长生命周期 session, 让 fetchRange 复用 HTTP keep-alive 连接。
    /// 一首 5MB 歌按 256KB chunk 拉 20 次, 不复用就要 20 次 TLS 握手 ——
    /// NAS 的 cold-start 大头就是 TLS 握手时间。
    /// 8 路并发: 配合 CloudPlaybackSource 小文件全 prefetch 时 8 chunk 并发,
    /// 让 SFB.open() 跳读 mp3 各 chunk 时基本都 cache hit。Synology
    /// FileStation API 对单 IP 默认无并发限制 (实测 8 路稳定)。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: alternateTLSValidationEndpoint
            ),
            delegateQueue: nil
        )
    }()

    init(
        sourceID: String, host: String, port: Int, useSsl: Bool,
        connectionMode: SynologyConnectionMode,
        username: String,
        rememberDevice: Bool, deviceId: String?,
        alternateTLSValidationHostname: String? = nil
    ) {
        self.sourceID = sourceID
        self.api = SynologyAPI(
            host: host,
            port: port,
            useSsl: useSsl,
            connectionMode: connectionMode,
            alternateTLSValidationHostname: alternateTLSValidationHostname
        )
        self.username = username
        self.rememberDevice = rememberDevice
        self.deviceId = deviceId
        self.alternateTLSValidationHostname = alternateTLSValidationHostname
        self.alternateTLSValidationEndpoint = NetworkEndpointIdentity(
            scheme: useSsl ? "https" : "http",
            host: host,
            port: port
        )

        // Use Caches directory (survives app restarts, system can purge when low on storage)
        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func prepareDiagnosticConnection() async throws {
        _ = try await api.resolveBaseURL()
    }

    func connect() async throws {
        try await connect(forceReconnect: false)
    }

    /// 强制重建会话。并发的 401 共享同一次本地 session invalidation 和登录，
    /// 且不会用网络 logout 误注销另一请求刚建立的新 sid。
    func reconnect() async throws {
        if let reconnectTask {
            try await reconnectTask.value
            return
        }
        let rejectedSID = await api.sid
        let task = Task { [api, weak self] in
            await api.invalidateSession(ifMatches: rejectedSID)
            guard let self else { throw CancellationError() }
            try await self.connect(forceReconnect: true)
        }
        reconnectTask = task
        defer { reconnectTask = nil }
        try await task.value
    }

    private func connect(forceReconnect: Bool) async throws {
        if !forceReconnect, await api.isLoggedIn { return }

        if let existing = loginTask {
            // 多个 caller 等同一个 in-flight login 时打一条聚合日志, 方便确认
            // dedupe 在工作 ── 没这条日志时只能从 SynologyAPI:59 "login start"
            // 数量推测 (一次 login start + N 个 dedupe wait 是健康的, N 次
            // login start 才是 dedupe 失效)。
            plog("🔁 SynologySource '\(sourceID)' connect: joining existing in-flight login task")
            try await existing.value
            return
        }
        let task = Task { [api, username, rememberDevice, deviceId, sourceID] in
            // Re-read immediately before every real login instead of capturing
            // a possibly-empty value when SourceManager created this connector.
            // Before-first-unlock Keychain failures are retryable and must not
            // be converted into an empty-password DSM request or a password UI.
            let password: String
            switch KeychainService.passwordLookup(for: sourceID) {
            case .found(let savedPassword):
                password = savedPassword
            case .notFound:
                plog("⛔ SynologySource '\(sourceID)' connect aborted: no saved credential")
                await MainActor.run {
                    SourceAuthAlert.report(
                        sourceID: sourceID,
                        message: String(localized: "password_required_title")
                    )
                }
                throw SourceConnectionTerminalError(message: String(localized: "password_required_title"))
            case .temporarilyUnavailable(let status):
                plog("⏳ SynologySource '\(sourceID)' connect deferred: credential temporarily unavailable status=\(status)")
                throw SourceConnectionTerminalError(
                    message: String(localized: "credential_temporarily_unavailable")
                )
            case .failed(let status):
                plog("⛔ SynologySource '\(sourceID)' connect aborted: credential read failed status=\(status)")
                throw SourceConnectionTerminalError(
                    message: String(localized: "credential_read_failed")
                )
            }

            let result = await api.login(
                account: username, password: password,
                deviceName: rememberDevice ? "Primuse-iOS" : nil,
                deviceId: rememberDevice ? deviceId : nil
            )
            guard result.success else {
                let msg = result.errorMessage ?? "Login failed"
                // 只有 DSM 400 能通过重新输入解决。密码过期/强制修改、锁定、
                // 网络故障与 2FA 都保留真实错误，不能误导用户反复输入密码。
                if result.requiresCredentialPrompt {
                    await MainActor.run {
                        SourceAuthAlert.report(sourceID: sourceID, message: msg)
                    }
                }
                if result.needs2FA || result.errorCode != nil {
                    throw SourceConnectionTerminalError(message: msg)
                }
                throw result.underlyingError ?? SourceError.connectionFailed(msg)
            }
            await MainActor.run {
                SourceAuthAlert.clear(sourceID: sourceID)
            }
        }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    func disconnect() async {
        let wasConnecting = loginTask != nil || reconnectTask != nil
        loginTask?.cancel()
        reconnectTask?.cancel()
        if wasConnecting {
            // A failed adaptive-route probe must not wait for a logout request
            // on the same stalled endpoint. Cancelling the login task also
            // cancels URLSession and any pending certificate-trust waiter.
            await api.invalidateSession(ifMatches: nil)
            return
        }
        await api.logout()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(
                name: $0.name,
                path: $0.path,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modifiedDate: $0.modifiedTime,
                revision: SynologyFileRevisionPolicy.revision(
                    size: $0.size,
                    modifiedDate: $0.modifiedTime
                )
            )
        }
    }

    /// Download full file to cache for playback. Supports offline playback after first download.
    func localURL(for path: String) async throws -> URL {
        let cacheName = CacheFileNamePolicy.make(path: path)
        let fileURL = cacheDirectory.appendingPathComponent(cacheName)

        // Already cached — return immediately (works offline)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let url = try await authenticatedDownloadURL(for: path)

        // Download to temp file first, then move to cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 min for large files
        config.timeoutIntervalForResource = 600 // 10 min total
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: alternateTLSValidationEndpoint
            ),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await TrustedHTTPTransport.download(
            from: url,
            session: session,
            timeout: 300
        )

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Move to cache
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        return fileURL
    }

    func streamingURL(for path: String) async throws -> URL? {
        let url = try await authenticatedDownloadURL(for: path)
        // ATS cannot dynamically authorize a user-provided public HTTP host.
        // Keep those URLs inside the connector so every byte goes through the
        // explicit-trust lower-level transport instead of escaping to the
        // player as a URLSession-backed direct URL.
        return TrustedHTTPTransport.requiresPlainSocket(for: url) ? nil : url
    }

    private func authenticatedDownloadURL(for path: String) async throws -> URL {
        try await connect()
        guard let sid = await api.sid else { throw SynologyError.notLoggedIn }

        let baseURL = try await api.resolvedBaseURLString()
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = SynologyQueryURLBuilder.url(from: components) else {
            throw SynologyError.invalidURL
        }
        return url
    }

    /// HTTP Range GET on FileStation Download API. NAS 原生支持 Range header,
    /// 让 CloudPlaybackSource 能按需拉 chunk 而不是整下整首歌 ——
    /// 实测 40MB flac 从"等 6.1s 整下"变成"~500ms 出第一个 buffer"。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        do {
            return try await fetchRangeOnce(path: path, offset: offset, length: length)
        } catch SynologyError.notLoggedIn {
            // 会话过期 (401)。之前这里直接把 notLoggedIn 抛给上层, 但 sid 没被
            // 清除, 重试再进 connect() 又被 isLoggedIn 短路, 重连永远不发生。
            // 现在: 强制重建会话后原地重试一次。仍失败才向上抛。
            try await reconnect()
            do {
                return try await fetchRangeOnce(path: path, offset: offset, length: length)
            } catch SynologyError.notLoggedIn {
                throw SourceError.authenticationFailed
            }
        }
    }

    private func fetchRangeOnce(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let url = try await authenticatedDownloadURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 60

        let maxBytes = Int(clamping: max(length, 0))
        let responseLimit = maxBytes > Int.max - 64 * 1024 ? Int.max : maxBytes + 64 * 1024
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: rangeSession,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
        guard let http = response as? HTTPURLResponse else {
            throw SynologyError.httpError(0)
        }

        switch http.statusCode {
        case 206:
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid Synology Content-Range response")
            }
            return data
        case 200:
            // ⚠️ FileStation Download 的失败响应 (sid 过期 error 119、路径不存在
            // error 408 等) 正是 HTTP 200 + JSON 错误体。若不校验就把这段 JSON
            // 字节切片当音频 chunk 返回, 会写进 .partial 缓存把它永久损坏。
            // 先识别"这是错误包还是真音频": Content-Type=JSON 或首字节是 '{'
            // 都视为错误体, 解析错误码 —— 会话类错误清 sid 抛 notLoggedIn 触发
            // reconnect-and-retry, 其余抛 apiError。
            if let error = synologyErrorPacket(data: data, response: http) {
                switch SynologyFileStationDownloadErrorPolicy.disposition(code: error) {
                case .reconnectSession:
                    throw SynologyError.notLoggedIn
                case .missingFile:
                    throw SourceError.fileNotFound(path)
                case .sourceUnavailable:
                    throw SourceError.authenticationFailed
                case .fail:
                    throw SynologyError.apiError(synologyErrorMessage(code: error))
                }
            }
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("Synology server ignored the byte Range request")
            }
            return data
        case 401:
            // Session expired —— surface as notLoggedIn so fetchRange can
            // reconnect-and-retry (and so it stays distinct from other HTTP
            // errors that should not trigger a re-login).
            throw SynologyError.notLoggedIn
        default:
            throw SynologyError.httpError(http.statusCode)
        }
    }

    // MARK: - 读标签用的有界读取

    /// 读标签走的有界读取, 播放用的 `fetchRange` 不变(稀疏缓存要它那套严格校验)。
    /// File Station 的 Download 接口认正向 Range; 这里另外兜住两种情况:
    /// - 服务器或中间的反向代理不认 Range、回 200 整个文件: 响应体只吃到要的那段前缀,
    ///   尾部与离开头太远的读取一个字节都不读(`WholeResourceMetadataRangePolicy`)。
    ///   以前同样的响应会先把整个文件(最多 20 MB)读进内存再报错, 一首歌读标签要几十秒。
    /// - 尾部读取不依赖 DSM 认不认 `bytes=-N`: 首段的 206 已经报了文件多大, 换成正向区间。
    /// 手动重读需要整首时, 和播放共用 `localURL(for:)` 那份完整缓存。
    func fetchMetadataRange(
        path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        do {
            return try await fetchMetadataRangeOnce(path: path, offset: offset, length: length, intent: intent)
        } catch SynologyError.notLoggedIn {
            try await reconnect()
            do {
                return try await fetchMetadataRangeOnce(path: path, offset: offset, length: length, intent: intent)
            } catch SynologyError.notLoggedIn {
                throw SourceError.authenticationFailed
            }
        }
    }

    private func fetchMetadataRangeOnce(
        path: String,
        offset requestedOffset: Int64,
        length requestedLength: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        guard let window = MetadataRangeWindowPolicy.resolvedWindow(
            offset: requestedOffset,
            length: requestedLength,
            knownFileSize: metadataRangeIgnored ? nil : metadataFileSizes[path]
        ) else { return Data() }
        let offset = window.offset
        let length = window.length
        let consumesPrefix = WholeResourceMetadataRangePolicy.consumesWholeResponsePrefix(
            requestedOffset: offset,
            requestedLength: length
        )
        if metadataRangeIgnored, !consumesPrefix {
            return try await metadataRangeWithoutRangeSupport(path: path, offset: offset, length: length, intent: intent)
        }
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        let url = try await authenticatedDownloadURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 60
        let requestedBodyBytes = Int(clamping: length)
        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: rangeSession,
            maximumRangedBodyBytes: requestedBodyBytes > Int.max - 64 * 1024
                ? Int.max
                : requestedBodyBytes + 64 * 1024,
            wholeResponsePrefixLimit: WholeResourceMetadataRangePolicy.wholeResponsePrefixLimit(
                requestedOffset: offset,
                requestedLength: length
            )
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw SynologyError.httpError(0) }
        switch http.statusCode {
        case 206:
            // 临时文件最多比要的多 64 KB, 整个读进来按实际长度校验。
            let body = try Data(contentsOf: temporaryURL)
            guard let total = HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: body.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw MetadataRangeReadError.invalidRangeResponse
            }
            if total > 0 {
                if metadataFileSizes.count >= 512 { metadataFileSizes.removeAll() }
                metadataFileSizes[path] = total
            }
            return body
        case 200:
            // 失败也是 200 + JSON 错误体(会话过期 119、路径不存在 408 …)。前缀限额可能
            // 只收了几个字节甚至没收, 声明是 JSON 的另外完整取一次这个小响应体再认错误码。
            let prefix = try Self.metadataSlice(of: temporaryURL, offset: 0, length: 4 * 1024, allowsEmpty: true)
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("json") || prefix.first == UInt8(ascii: "{") {
                try await throwFileStationErrorIfPresent(request: request, path: path)
            }
            // 从头读、要的长度已经盖住整个文件时回 200 是正常的, 不算不认 Range。
            if !metadataRangeIgnored, MetadataRangeWindowPolicy.wholeResponseShowsRangeIgnored(
                requestedOffset: offset,
                requestedLength: length,
                contentLength: http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            ) {
                metadataRangeIgnored = true
                plog("⚠️ Synology '\(sourceID.prefix(8))' metadata read: server ignored Range; reading only bounded prefixes")
            }
            switch WholeResourceMetadataRangePolicy.responseDisposition(
                requestedOffset: offset,
                requestedLength: length,
                intent: intent
            ) {
            case .consumeBoundedPrefix:
                return try Self.metadataSlice(of: temporaryURL, offset: offset, length: length)
            case .rejectSuffixWithoutConsuming, .useCompleteFileFallback:
                return try await metadataRangeWithoutRangeSupport(
                    path: path, offset: offset, length: length, intent: intent
                )
            }
        case 401:
            throw SynologyError.notLoggedIn
        default:
            throw SynologyError.httpError(http.statusCode)
        }
    }

    /// 不认 Range 时首段以外的读取: 批量读取直接拒绝(回填按「尾部读不了」处理), 用户点的
    /// 单曲重读下载整首一次再切。
    private func metadataRangeWithoutRangeSupport(
        path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        switch intent {
        case .bulkBounded:
            throw MetadataRangeReadError.suffixRangeUnsupported
        case .explicitSingleFileCompleteFallback:
            let file = try await localURL(for: path)
            return try Self.metadataSlice(of: file, offset: offset, length: length)
        }
    }

    /// 200 响应声明是 JSON 时, 取完整的小响应体认错误码; 不是错误包就当没事。
    private func throwFileStationErrorIfPresent(request: URLRequest, path: String) async throws {
        let result: (Data, URLResponse)
        do {
            result = try await TrustedHTTPTransport.data(
                for: request,
                session: rangeSession,
                maxBytes: 64 * 1024
            )
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            return // 比错误包大得多: 是音频本身。
        }
        let (body, response) = result
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let code = synologyErrorPacket(data: body, response: http) else { return }
        switch SynologyFileStationDownloadErrorPolicy.disposition(code: code) {
        case .reconnectSession:
            throw SynologyError.notLoggedIn
        case .missingFile:
            throw SourceError.fileNotFound(path)
        case .sourceUnavailable:
            throw SourceError.authenticationFailed
        case .fail:
            throw SynologyError.apiError(synologyErrorMessage(code: code))
        }
    }

    private static func metadataSlice(
        of fileURL: URL,
        offset: Int64,
        length: Int64,
        allowsEmpty: Bool = false
    ) throws -> Data {
        guard length > 0, offset != Int64.min else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let total = Int64(clamping: try handle.seekToEnd())
        let start = offset < 0 ? max(0, total + offset) : offset
        guard start < total else {
            if allowsEmpty { return Data() }
            throw SourceError.connectionFailed("Synology metadata response was empty")
        }
        try handle.seek(toOffset: UInt64(start))
        return try handle.read(upToCount: Int(clamping: min(length, total - start))) ?? Data()
    }

    /// Returns the local cache URL if the file is already cached, nil otherwise.
    nonisolated func cachedURL(for path: String) -> URL? {
        let cacheName = CacheFileNamePolicy.make(path: path)
        let fileURL = cacheDirectory.appendingPathComponent(cacheName)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Download file to cache in background (for offline support).
    func cacheFile(for path: String) async throws {
        // Skip if already cached
        let cacheName = CacheFileNamePolicy.make(path: path)
        let fileURL = cacheDirectory.appendingPathComponent(cacheName)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let url = try await authenticatedDownloadURL(for: path)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: alternateTLSValidationEndpoint
            ),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await TrustedHTTPTransport.download(
            from: url,
            session: session,
            timeout: 300
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }

        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
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

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    Task.isCancelled ? continuation.finish() : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let items = try await listFiles(at: path)
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else if let scannable = SidecarHintResolver.scannableItem(
                item,
                index: sidecarIndex
            ) {
                continuation.yield(scannable)
            }
        }
    }

    /// Cache size for this source
    func cacheSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Clear cached files
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func writeFile(data: Data, to path: String) async throws {
        try await connect()
        let directory = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        try await api.uploadFile(data: data, toDirectory: directory, fileName: fileName)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        try await listedMetadataWritebackState(for: path)
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        try await connect()
        let directory = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let stagingName = ".primuse-writeback-\(UUID().uuidString)"
        let stagingPath = (directory as NSString).appendingPathComponent(stagingName)

        try await api.createDirectory(name: stagingName, at: directory)
        do {
            try await api.uploadFile(
                localURL: localURL,
                toDirectory: stagingPath,
                fileName: fileName,
                overwrite: false
            )
            let current = try await metadataWritebackState(for: path)
            guard expected.matches(current) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            try await api.moveFile(
                at: (stagingPath as NSString).appendingPathComponent(fileName),
                toDirectory: directory,
                overwrite: true
            )
            try? await api.deleteTemporaryItem(path: stagingPath)
        } catch {
            try? await api.deleteTemporaryItem(path: stagingPath)
            throw error
        }
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(CacheFileNamePolicy.make(path: path))
        )
    }

    func deleteFile(at path: String) async throws {
        try await connect()
        try await api.deleteFile(path: path)
    }

    /// 在 HTTP 200 的 Range 响应里识别 Synology JSON 错误包。仅当确信是
    /// FileStation 的 `{"success":false,"error":{"code":N}}` 错误体时返回错误码;
    /// 真音频 (含恰好以 '{' 开头的二进制) 一律返回 nil 走正常切片。
    private func synologyErrorPacket(data: Data, response: HTTPURLResponse) -> Int? {
        // 只在响应明确声明 JSON, 或 body 以 '{' 开头时才尝试解析, 避免把以
        // 0x7B 开头的音频帧误判成错误包。
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksJSON = contentType.contains("application/json") || data.first == UInt8(ascii: "{")
        guard looksJSON else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 只有 success==false 才是错误包; success==true 的下载元信息极罕见,
        // 也不应被当作音频写缓存, 这里仍按错误处理 (无 code 则给个通用码)。
        if json["success"] as? Bool == false {
            let err = json["error"] as? [String: Any]
            if let code = err?["code"] as? Int { return code }
            if let number = (err?["code"] as? NSNumber)?.intValue { return number }
            return -1
        }
        return nil
    }

    private func synologyErrorMessage(code: Int) -> String {
        switch code {
        case 119: return String(localized: "synology_session_expired")
        case 408: return String(localized: "file_not_found_generic")
        case 407, 410: return String(localized: "auth_access_denied")
        default: return String(format: String(localized: "synology_download_failed_code_format"), code)
        }
    }
}
