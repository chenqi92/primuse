import Foundation
import PrimuseKit

actor SynologySource: MusicSourceConnector {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true

    private let api: SynologyAPI
    private let username: String
    private let password: String
    private let rememberDevice: Bool
    private let deviceId: String?
    private let cacheDirectory: URL
    /// In-flight login dedupe. 多个 connect() 同时被预取/解码路径调起时,
    /// 让首个发起的登录跑,后面的全部 await 同一个 Task。否则 actor 重入
    /// 会让 N 路并发各自打一发 login,触发 DSM 的「自动封禁」(实测短时
    /// 60+ 次登录被 407 拒, 之后即便密码对也被回 400 用户名/密码错误)。
    private var loginTask: Task<Void, Error>?

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
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    init(
        sourceID: String, host: String, port: Int, useSsl: Bool,
        username: String, password: String,
        rememberDevice: Bool, deviceId: String?
    ) {
        self.sourceID = sourceID
        self.api = SynologyAPI(host: host, port: port, useSsl: useSsl)
        self.username = username
        self.password = password
        self.rememberDevice = rememberDevice
        self.deviceId = deviceId

        // Use Caches directory (survives app restarts, system can purge when low on storage)
        let cacheDir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        try await connect(forceReconnect: false)
    }

    /// 强制重建会话: 先清掉过期 sid 再重新登录。
    /// 普通 connect() 在 isLoggedIn 时短路返回, DSM 会话过期 / NAS 重启后
    /// sid 仍非 nil, 重连永远不会发生 —— fetchRange 拿到 401 抛 notLoggedIn,
    /// 任何重试再进 connect() 又被短路。这里跳过短路, 调 logout() 清 sid
    /// (best-effort, 同时设 sid=nil), 再走正常登录, 让会话真正续上。
    func reconnect() async throws {
        await api.logout()
        try await connect(forceReconnect: true)
    }

    private func connect(forceReconnect: Bool) async throws {
        if !forceReconnect, await api.isLoggedIn { return }

        // 空密码 guard ── 关键保护机制。
        //
        // 之前没这个 guard 时, keychain 暂时不可访问 (kSecAttrAccessibleAfterFirstUnlock
        // 在 app 冷启动 + 设备锁屏状态下读不到密码) 会导致 KeychainService.getPassword
        // 返回 nil, 上层 fallback 成空字符串, 然后 connect() 拿空密码反复打 NAS,
        // DSM 把 IP / 账号锁掉, 此后哪怕密码恢复了所有歌也都 connectionFailed
        // ── 实测连续几十首歌全部 "登录尝试次数过多, 请稍后再试"。
        //
        // 这里直接 throw, UI 层会拿到 connectionFailed 并通过 SourceAuthAlert
        // 弹"重新输入密码"。比浪费几次失败 login + 触发 NAS 端 lockout 强得多。
        if password.isEmpty {
            plog("⛔ SynologySource '\(sourceID)' connect aborted: password unavailable (keychain not yet accessible or credential cleared)")
            await MainActor.run {
                SourceAuthAlert.report(sourceID: sourceID, message: "缺少登录密码 ── 请重新输入")
            }
            throw SourceError.connectionFailed("missing password")
        }

        if let existing = loginTask {
            // 多个 caller 等同一个 in-flight login 时打一条聚合日志, 方便确认
            // dedupe 在工作 ── 没这条日志时只能从 SynologyAPI:59 "login start"
            // 数量推测 (一次 login start + N 个 dedupe wait 是健康的, N 次
            // login start 才是 dedupe 失效)。
            plog("🔁 SynologySource '\(sourceID)' connect: joining existing in-flight login task")
            try await existing.value
            return
        }
        let task = Task { [api, username, password, rememberDevice, deviceId, sourceID] in
            let result = await api.login(
                account: username, password: password,
                deviceName: rememberDevice ? "Primuse-iOS" : nil,
                deviceId: rememberDevice ? deviceId : nil
            )
            guard result.success else {
                let msg = result.errorMessage ?? "Login failed"
                // 通知 UI 层弹"重新输入密码"。节流在 SourceAuthAlert 里做,
                // 60s 同 sourceID 只弹一次。失败原因(密码错/限流/网络挂)
                // 都走这条,因为表象都是"现在登不上",修法都得用户介入。
                await MainActor.run {
                    SourceAuthAlert.report(sourceID: sourceID, message: msg)
                }
                throw result.needs2FA
                    ? SourceError.authenticationFailed
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

    func disconnect() async {
        await api.logout()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size, modifiedDate: nil)
        }
    }

    /// Download full file to cache for playback. Supports offline playback after first download.
    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)

        // Already cached — return immediately (works offline)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        // Must be online to download
        try await connect()

        guard let sid = await api.sid else { throw SynologyError.notLoggedIn }

        // Build download URL
        let baseURL = await api.baseURLString
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { throw SynologyError.invalidURL }

        // Download to temp file first, then move to cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 min for large files
        config.timeoutIntervalForResource = 600 // 10 min total
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Move to cache
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        return fileURL
    }

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()
        guard let sid = await api.sid else { throw SynologyError.notLoggedIn }

        let baseURL = await api.baseURLString
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        return components.url
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
            return try await fetchRangeOnce(path: path, offset: offset, length: length)
        }
    }

    private func fetchRangeOnce(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        guard let url = try await streamingURL(for: path) else {
            throw SynologyError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60

        let (data, response) = try await rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SynologyError.httpError(0)
        }

        switch http.statusCode {
        case 206:
            return data
        case 200:
            // ⚠️ FileStation Download 的失败响应 (sid 过期 error 119、路径不存在
            // error 408 等) 正是 HTTP 200 + JSON 错误体。若不校验就把这段 JSON
            // 字节切片当音频 chunk 返回, 会写进 .partial 缓存把它永久损坏。
            // 先识别"这是错误包还是真音频": Content-Type=JSON 或首字节是 '{'
            // 都视为错误体, 解析错误码 —— 会话类错误清 sid 抛 notLoggedIn 触发
            // reconnect-and-retry, 其余抛 apiError。
            if let error = synologyErrorPacket(data: data, response: http) {
                if isSessionError(code: error) {
                    throw SynologyError.notLoggedIn
                }
                throw SynologyError.apiError(synologyErrorMessage(code: error))
            }
            // Server ignored Range — slice the returned full body to the
            // requested window so callers can trust offsets. Without this,
            // a seek-to-middle would write the start of the file into the
            // middle of `.partial` and corrupt the cache permanently.
            let total = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: actualOffset, length: length) else {
                return Data()
            }
            let upper = min(requestedEnd, total)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        case 401:
            // Session expired —— surface as notLoggedIn so fetchRange can
            // reconnect-and-retry (and so it stays distinct from other HTTP
            // errors that should not trigger a re-login).
            throw SynologyError.notLoggedIn
        default:
            throw SynologyError.httpError(http.statusCode)
        }
    }

    /// Returns the local cache URL if the file is already cached, nil otherwise.
    nonisolated func cachedURL(for path: String) -> URL? {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Download file to cache in background (for offline support).
    func cacheFile(for path: String) async throws {
        // Skip if already cached
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        guard let url = try await streamingURL(for: path) else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)
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

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(at: path)
        for item in items {
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else if let scannable = SidecarHintResolver.scannableItem(item, siblings: items) {
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

    /// 会话过期类错误码: 119 (sid 过期 / 无效)、105/106/107 (会话相关)。
    /// 这些清 sid 并 reconnect-and-retry; 其余 (如 408 路径不存在) 直接抛。
    private func isSessionError(code: Int) -> Bool {
        code == 119 || code == 105 || code == 106 || code == 107 || code == 100
    }

    private func synologyErrorMessage(code: Int) -> String {
        switch code {
        case 119: return "会话已过期，请重新登录"
        case 408: return "文件不存在"
        case 407, 410: return "无访问权限"
        default: return "Synology 下载失败 (错误码: \(code))"
        }
    }
}
