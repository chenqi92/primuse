import Foundation
import PrimuseKit

actor QnapSource: MusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    private let api: QnapAPI
    private let username: String
    private let password: String
    private let alternateTLSValidationHostname: String?
    private let alternateTLSValidationEndpoint: NetworkEndpointIdentity?
    private let cacheDirectory: URL

    /// In-flight login dedupe. 多个 connect() 被 8 路并发 chunk 预取/解码路径
    /// 同时调起时, actor 重入会让 N 路各自打一发 login, 触发 QNAP 端封禁
    /// (qnapError code 7 "IP 已被封锁" / code 4 "连接数已满")。让首个发起的
    /// 登录跑, 后面的全部 await 同一个 Task。
    private var loginTask: Task<Void, Error>?

    /// 长生命周期 session, fetchRange 复用 HTTP keep-alive。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: alternateTLSValidationEndpoint
            ),
            delegateQueue: nil
        )
    }()

    init(sourceID: String, host: String, port: Int, useSsl: Bool,
         username: String, password: String,
         alternateTLSValidationHostname: String? = nil) {
        self.sourceID = sourceID
        self.api = QnapAPI(
            host: host,
            port: port,
            useSsl: useSsl,
            alternateTLSValidationHostname: alternateTLSValidationHostname
        )
        self.username = username; self.password = password
        self.alternateTLSValidationHostname = alternateTLSValidationHostname
        self.alternateTLSValidationEndpoint = NetworkEndpointIdentity(
            scheme: useSsl ? "https" : "http",
            host: host,
            port: port
        )
        let dir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
    }

    func connect() async throws {
        guard await !api.isLoggedIn else { return }

        // 空密码 guard: keychain 暂不可读 (冷启动 + 锁屏) 时上层 fallback 成
        // 空字符串, 拿空密码反复撞 NAS 会触发账号/IP 锁定。直接抛错让 UI 弹
        // "重新输入密码", 比浪费失败 login 触发 lockout 强。
        if password.isEmpty {
            plog("⛔ QnapSource '\(sourceID)' connect aborted: password unavailable")
            await MainActor.run {
                SourceAuthAlert.report(sourceID: sourceID, message: String(localized: "auth_missing_password"))
            }
            throw SourceConnectionTerminalError(message: String(localized: "auth_missing_password"))
        }

        // In-flight login dedupe: 并发 connect() 全部 await 同一个 login Task,
        // 避免 N 路并发各打一发 login 触发 QNAP 封禁。
        if let existing = loginTask {
            try await existing.value
            return
        }
        let task = Task { [api, username, password, sourceID] in
            let r = await api.login(account: username, password: password)
            guard r.success else {
                let msg = r.errorMessage ?? "QNAP login failed"
                await MainActor.run {
                    SourceAuthAlert.report(sourceID: sourceID, message: msg)
                }
                if let underlyingError = r.underlyingError {
                    throw underlyingError
                }
                throw SourceConnectionTerminalError(message: msg)
            }
            await MainActor.run {
                SourceAuthAlert.clear(sourceID: sourceID)
            }
        }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    func disconnect() async { await api.logout() }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(
                name: $0.name,
                path: $0.path.isEmpty ? "\(path)/\($0.name)" : $0.path,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modifiedDate: $0.modifiedDate,
                revision: Self.fileRevision(size: $0.size, modifiedDate: $0.modifiedDate)
            )
        }
    }

    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        try await connect()
        guard let url = await api.downloadURL(path: path) else { throw SourceError.fileNotFound(path) }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 600
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
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
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SourceError.connectionFailed("Invalid QNAP download response")
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SourceError.connectionFailed("QNAP download failed: HTTP \(http.statusCode)")
        }
        // ⚠️ sid 过期 / 路径错误 时 QNAP 可能回 HTTP 200 + JSON / HTML 登录页, 而非
        // 二进制音频。把错误体落进缓存会永久损坏这首歌 (后续命中缓存直接返回坏文件)。
        // 先按 Content-Type / 文件首字节嗅探: 非音频体一律抛错, 绝不落缓存。
        let prefix = (try? FileHandle(forReadingFrom: tempURL))
            .map { h -> Data in defer { h.closeFile() }; return h.readData(ofLength: 64) } ?? Data()
        if httpMediaResponseLooksLikeErrorBody(http, data: prefix) {
            try? FileManager.default.removeItem(at: tempURL)
            await api.invalidateSession()
            throw SourceError.connectionFailed("QNAP download returned non-audio body (session expired?)")
        }
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        return fileURL
    }

    func writeFile(data: Data, to path: String) async throws {
        try await connect()
        let parent = Self.parentPath(of: path)
        let name = (path as NSString).lastPathComponent
        try await api.uploadFile(
            data: data,
            toDirectory: parent,
            fileName: name,
            overwrite: true
        )
        await invalidateMetadataWritebackCache(for: path)
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
        let parent = Self.parentPath(of: path)
        let name = (path as NSString).lastPathComponent
        let stagingName = ".primuse-writeback-\(UUID().uuidString)"
        let stagingPath = (parent as NSString).appendingPathComponent(stagingName)

        try await api.createDirectory(name: stagingName, at: parent)
        do {
            try await api.uploadFile(
                localURL: localURL,
                toDirectory: stagingPath,
                fileName: name,
                overwrite: false
            )
            let current = try await metadataWritebackState(for: path)
            guard expected.matches(current) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            try await api.moveFile(
                named: name,
                from: stagingPath,
                to: parent,
                overwrite: true
            )
            try await waitForMoveCompletion(fileName: name, stagingPath: stagingPath)
        } catch {
            try? await api.deleteTemporaryItem(path: stagingPath)
            throw error
        }
        try? await api.deleteTemporaryItem(path: stagingPath)
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(sanitized)
        )
    }

    private func waitForMoveCompletion(
        fileName: String,
        stagingPath: String
    ) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let remaining = try await api.listDirectory(path: stagingPath)
            if !remaining.contains(where: { $0.name == fileName }) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SourceError.timeout
    }

    private nonisolated static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private nonisolated static func fileRevision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "qnap:\(size):\(Int64(modifiedDate.timeIntervalSince1970))"
    }

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()
        guard let url = await api.downloadURL(path: path) else { return nil }
        // Public cleartext URLs must stay inside the connector so playback
        // cannot escape to an ATS-enforced URLSession without the host gate.
        return TrustedHTTPTransport.requiresPlainSocket(for: url) ? nil : url
    }

    func deleteFile(at path: String) async throws {
        try await connect()
        try await api.deleteFile(path: path)
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(sanitized))
        plog("🗑️ QNAP item moved to recycle bin: \(path)")
    }

    /// HTTP Range GET on QNAP download URL。downloadURL 返回的 URL 已带认证
    /// (sid query param), 标准 Range header 直接生效, 让 CloudPlaybackSource
    /// 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        guard let url = await api.downloadURL(path: path) else {
            throw SourceError.fileNotFound(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
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
            throw SourceError.connectionFailed("Invalid QNAP range response")
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
                throw SourceError.connectionFailed("Invalid QNAP Content-Range response")
            }
            return data
        case 200:
            // ⚠️ token 过期 / 路径错误 时 QNAP 可能回 HTTP 200 + JSON / HTML
            // 登录页, 而非二进制音频。把这段错误体切片当 chunk 返回会写进
            // .partial 缓存并永久损坏它。先按 Content-Type 识别: 非音频体一律
            // 抛错而不是切片。
            if httpMediaResponseLooksLikeErrorBody(http, data: data) {
                await api.invalidateSession()
                throw SourceError.connectionFailed("QNAP range returned non-audio body (session expired?)")
            }
            guard HTTPByteRangeResponsePolicy.acceptsWholeResourceResponse(
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) else {
                throw SourceError.connectionFailed("QNAP server ignored the byte Range request")
            }
            return data
        default:
            throw SourceError.connectionFailed("QNAP range request failed: HTTP \(http.statusCode)")
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let local = try await localURL(for: path)
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    let h = try FileHandle(forReadingFrom: local); defer { h.closeFile() }
                    while true { let d = h.readData(ofLength: 65536); if d.isEmpty { break }; c.yield(d) }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    try await scan(path: path, c: c)
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private func scan(path: String, c: AsyncThrowingStream<RemoteFileItem, Error>.Continuation) async throws {
        try Task.checkCancellation()
        let items = try await listFiles(at: path)
        let sidecarIndex = SidecarHintResolver.DirectoryIndex(items)
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory { try await scan(path: item.path, c: c) }
            else if let scannable = SidecarHintResolver.scannableItem(
                item,
                index: sidecarIndex
            ) {
                c.yield(scannable)
            }
        }
    }
}

/// 共享判定: NAS download 端点在会话失效时常回 HTTP 200 + JSON / HTML 登录页。
/// 把这种 body 切片当 chunk 会损坏 .partial 缓存, 所以先嗅探内容类型。
func httpMediaResponseLooksLikeErrorBody(_ http: HTTPURLResponse, data: Data) -> Bool {
    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    if contentType.contains("application/json")
        || contentType.contains("text/html")
        || contentType.hasPrefix("text/") {
        return true
    }
    // 无 / 含糊 Content-Type 时按首个非空字节兜底: JSON '{'、HTML '<'。
    if let first = data.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\n")
        && $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\t") }) {
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "<") {
            return true
        }
    }
    return false
}
