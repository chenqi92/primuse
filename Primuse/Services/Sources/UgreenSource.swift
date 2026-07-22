import Foundation
import PrimuseKit

actor UgreenSource: MusicSourceConnector {
    let sourceID: String
    private let api: UgreenAPI
    private let username: String
    private let password: String
    private let cacheDirectory: URL

    /// In-flight login dedupe. 多个 connect() 被 8 路并发 chunk 预取/解码路径
    /// 同时调起时, actor 重入会让 N 路各自打一发 login, 触发 NAS 端封禁。
    /// 让首个发起的登录跑, 后面的全部 await 同一个 Task。
    private var loginTask: Task<Void, Error>?

    /// 长生命周期 session, fetchRange 复用 HTTP keep-alive。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    init(sourceID: String, host: String, port: Int, useSsl: Bool,
         username: String, password: String) {
        self.sourceID = sourceID
        self.api = UgreenAPI(host: host, port: port, useSsl: useSsl)
        self.username = username; self.password = password
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
            plog("⛔ UgreenSource '\(sourceID)' connect aborted: password unavailable")
            await MainActor.run {
                SourceAuthAlert.report(sourceID: sourceID, message: "缺少登录密码 ── 请重新输入")
            }
            throw SourceError.connectionFailed("missing password")
        }

        // In-flight login dedupe: 并发 connect() 全部 await 同一个 login Task,
        // 避免 N 路并发各打一发 login 触发 NAS 封禁。
        if let existing = loginTask {
            try await existing.value
            return
        }
        let task = Task { [api, username, password, sourceID] in
            let r = await api.login(account: username, password: password)
            guard r.success else {
                let msg = r.errorMessage ?? "Ugreen login failed"
                await MainActor.run {
                    SourceAuthAlert.report(sourceID: sourceID, message: msg)
                }
                throw r.needs2FA ? SourceError.authenticationFailed
                                 : SourceError.connectionFailed(msg)
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
            RemoteFileItem(name: $0.name, path: $0.path.isEmpty ? "\(path)/\($0.name)" : $0.path,
                          isDirectory: $0.isDirectory, size: $0.size, modifiedDate: nil)
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
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, _) = try await session.download(from: url)
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        return fileURL
    }

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()
        return await api.downloadURL(path: path)
    }

    /// HTTP Range GET on Ugreen download URL。downloadURL 返回的 URL 已带认证,
    /// 标准 Range header 直接生效, 让 CloudPlaybackSource 边下边播替代整文件
    /// 下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        guard let url = await api.downloadURL(path: path) else {
            throw SourceError.fileNotFound(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60

        let (data, response) = try await rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid Ugreen range response")
        }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            // ⚠️ token 过期 / 路径错误 时绿联可能回 HTTP 200 + JSON / HTML 登录
            // 页, 而非二进制音频。把这段错误体切片当 chunk 返回会写进 .partial
            // 缓存并永久损坏它。先按 Content-Type 识别: 非音频体一律抛错并清
            // token 而不是切片。
            if nasResponseLooksLikeErrorBody(http, data: data) {
                await api.invalidateSession()
                throw SourceError.connectionFailed("Ugreen range returned non-audio body (session expired?)")
            }
            let total = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: actualOffset, length: length) else {
                return Data()
            }
            let upper = min(requestedEnd, total)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw SourceError.connectionFailed("Ugreen range request failed: HTTP \(http.statusCode)")
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
        for item in items {
            try Task.checkCancellation()
            if item.isDirectory { try await scan(path: item.path, c: c) }
            else if let scannable = SidecarHintResolver.scannableItem(item, siblings: items) {
                c.yield(scannable)
            }
        }
    }
}
