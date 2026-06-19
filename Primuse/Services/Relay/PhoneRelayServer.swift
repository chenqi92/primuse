#if os(iOS) || os(macOS)
import Foundation
import Network
import PrimuseKit

/// Phase 3:iPhone / Mac 局域网 HTTP 中继。让 Apple TV 播放本地 / SMB / SFTP / NFS /
/// WebDAV 等"不可直连 tvOS"的源:TV 经 `http://<本机IP>:<端口>/stream?source=&path=&token=`
/// 拉流,本服务用 SourceManager 取字节回传(支持 Range)。
///
/// 安全默认:① 只服务音乐库里**存在**的 (source, path);② URL 必须带正确随机 token;
/// ③ 默认关闭,用户在设置里开(UserDefaults `phoneRelayEnabled`)。
final class PhoneRelayServer: @unchecked Sendable {
    static let shared = PhoneRelayServer()

    static let enabledKey = "phoneRelayEnabled"

    private let queue = DispatchQueue(label: "com.welape.primuse.relay")
    private var listener: NWListener?
    private let token = UUID().uuidString
    private var boundPort: UInt16?

    /// 半开连接防护:凑齐请求头前的 idle 超时 + 并发连接上限,防 LAN 端
    /// slow-loris 式拖死 fd。计数与连接处理同跑 `queue`(串行),无需额外锁。
    private static let headerTimeout: TimeInterval = 12
    private static let maxConnections = 16
    private var activeConnections = 0

    private var sourceManager: SourceManager?
    private weak var sourcesStore: SourcesStore?
    private weak var library: MusicLibrary?

    /// 开放式 range(bytes=N- / 无 Range 头)单次响应的最大窗口(8MB)。
    /// 客户端(AVPlayer)用后续 Range 请求续传剩余字节。
    private static let openRangeWindow: Int64 = 8 * 1024 * 1024
    /// 流式回传的分块大小(256KB),避免把整段 range 一次性载入内存。
    private static let streamChunkSize: Int64 = 256 * 1024

    private init() {}

    @MainActor
    func startIfEnabled(sourceManager: SourceManager, sourcesStore: SourcesStore, library: MusicLibrary) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.boundPort = nil
        }
    }

    /// 当前中继端点(供凭据包同步给 TV)。未运行 / 无 Wi-Fi 时 nil。
    func endpoint() -> RelayEndpoint? {
        guard let port = boundPort, let ip = Self.wifiIPv4() else { return nil }
        return RelayEndpoint(host: ip, port: Int(port), token: token)
    }

    // MARK: - Listener

    private func startListener() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.stateUpdateHandler = { [weak self, weak l] state in
                if case .ready = state { self?.boundPort = l?.port?.rawValue }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                self.acceptConnection(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            plog("Relay: listener start failed — \(error)")
        }
    }

    /// accept 路径:超并发上限直接 cancel(防 fd 无限累积);否则记账 +
    /// 挂 header idle 超时(凑齐请求头前若超时未推进就 cancel),并在连接终态
    /// 统一扣并发计数 + 停 timer。此回调已跑在 `queue`(串行),计数无需额外锁。
    private func acceptConnection(_ conn: NWConnection) {
        guard activeConnections < Self.maxConnections else {
            conn.cancel(); return
        }
        activeConnections += 1
        let headerTimer = DispatchSource.makeTimerSource(queue: queue)
        headerTimer.schedule(deadline: .now() + Self.headerTimeout)
        headerTimer.setEventHandler { [weak conn] in
            plog("Relay: connection header timeout, closing")
            conn?.cancel()
        }
        headerTimer.resume()
        // 连接终态统一在这里扣并发计数 + 停 timer,无论正常收尾、超时还是出错,
        // 都只走这一处,避免在 readHead/handle 的多个出口逐一处理漏算。
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                headerTimer.cancel()
                if let self, self.activeConnections > 0 { self.activeConnections -= 1 }
            default:
                break
            }
        }
        conn.start(queue: queue)
        readHead(conn, buffer: Data(), headerTimer: headerTimer)
    }

    private func readHead(_ conn: NWConnection, buffer: Data, headerTimer: DispatchSourceTimer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                // header 收齐,idle timer 使命结束(后续 stream 可能很长不能限时)。
                headerTimer.cancel()
                let head = String(decoding: buf.subdata(in: buf.startIndex..<end.lowerBound), as: UTF8.self)
                self.handle(conn, head: head)
            } else if error == nil, !complete, buf.count < 64 * 1024 {
                self.readHead(conn, buffer: buf, headerTimer: headerTimer)
            } else {
                conn.cancel()
            }
        }
    }

    private func handle(_ conn: NWConnection, head: String) {
        guard let req = Self.parseRequest(head), req.path == "/stream",
              req.query["token"] == token,
              let sourceID = req.query["source"], let path = req.query["path"] else {
            Self.respond(conn, status: 403, headers: [:], body: Data()); return
        }
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            // 只服务库里存在的 (source, path),取文件大小与 connector(均在 MainActor)。
            let prep: (SourceManager, MusicSource, Int64)? = await MainActor.run {
                guard let manager = self.sourceManager,
                      let source = self.sourcesStore?.source(id: sourceID),
                      let song = self.library?.songs.first(where: { $0.sourceID == sourceID && $0.filePath == path })
                else { return nil }
                return (manager, source, song.fileSize)
            }
            guard let (manager, source, total) = prep, total > 0 else {
                Self.respond(conn, status: 404, headers: [:], body: Data()); return
            }
            let hasRange = req.range != nil
            let (start, parsedEnd) = Self.parseRange(req.range, total: total)
            // 开放式 range(bytes=N- / 无上界)只回一个有限窗口,客户端续传。避免
            // 把整首 100MB+ 的 FLAC/WAV 一次性载入内存(jetsam)、并让 TV 尽早起播。
            let end = Self.isOpenEndedRange(req.range)
                ? min(parsedEnd, start + Self.openRangeWindow - 1)
                : parsedEnd
            do {
                let connector = await MainActor.run { manager.connector(for: source) }
                // 无 Range 头返回 200,带 Range 返回 206(HTTP 语义)。
                var headers: [String: String] = [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                ]
                if hasRange {
                    headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
                }
                try await Self.respondStreaming(
                    conn, status: hasRange ? 206 : 200, headers: headers,
                    total: end - start + 1
                ) { offset, length in
                    try await connector.fetchRange(path: path, offset: start + offset, length: length)
                }
            } catch {
                Self.respond(conn, status: 502, headers: [:], body: Data())
            }
        }
    }

    // MARK: - 纯函数(可单测)

    static func parseRequest(_ head: String) -> (path: String, query: [String: String], range: String?)? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comp = URLComponents(string: String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in comp.queryItems ?? [] { query[item.name] = item.value }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        return (comp.path, query, range)
    }

    /// 解析 Range 头(bytes=a-b / bytes=a- / bytes=-N),夹到 [0, total-1]。
    static func parseRange(_ range: String?, total: Int64) -> (Int64, Int64) {
        guard let range, let eq = range.range(of: "bytes=") else { return (0, total - 1) }
        let spec = range[eq.upperBound...].split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.components(separatedBy: "-")
        if bounds.count == 2 {
            if let s = Int64(bounds[0]) {
                let e = Int64(bounds[1]) ?? (total - 1)
                return (max(0, s), min(max(s, e), total - 1))
            } else if let suffix = Int64(bounds[1]) {   // bytes=-N(末尾 N 字节)
                return (max(0, total - suffix), total - 1)
            }
        }
        return (0, total - 1)
    }

    /// 判断 range 是否开放式 —— 即"从某个起点一直要到文件末尾"(无 Range 头,
    /// 或 `bytes=N-` 这种没有显式上界的)。这类请求若不加窗口限制就会拉整首歌。
    /// 注意 `bytes=-N`(末尾 N 字节)是有限长度,不算开放式,不应被截断。
    static func isOpenEndedRange(_ range: String?) -> Bool {
        guard let range, let eq = range.range(of: "bytes=") else { return true }
        let spec = range[eq.upperBound...].split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.components(separatedBy: "-")
        guard bounds.count == 2 else { return true }
        // 有起点(bytes=N- / bytes=N-M):有显式上界则非开放式,缺上界则开放式。
        if Int64(bounds[0]) != nil { return Int64(bounds[1]) == nil }
        // 无起点:bytes=-N 是有限的末尾窗口,非开放式;其余不合法当开放式。
        return Int64(bounds[1]) == nil
    }

    private static func respond(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        let reason = [200: "OK", 206: "Partial Content", 403: "Forbidden",
                      404: "Not Found", 502: "Bad Gateway"][status] ?? "OK"
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 分块流式回传 `total` 字节:先发响应头,再循环调用 `fetch`(每块
    /// `streamChunkSize`)逐段 send,避免把整段 range 一次性载入内存。
    /// `fetch(offset, length)` 的 offset 相对窗口起点。第一块取数据失败会
    /// 抛错(调用方回 502);头部一旦发出,后续取数据失败只能中断连接。
    private static func respondStreaming(
        _ conn: NWConnection,
        status: Int,
        headers: [String: String],
        total: Int64,
        fetch: (_ offset: Int64, _ length: Int64) async throws -> Data
    ) async throws {
        // 网盘/SFTP 等流式源单块取数据偶发抖动(瞬时网络错误), 而头部一旦带着
        // Content-Length=total 发出, 中途取数据失败就只能截断 —— 客户端按声明长度
        // 苦等剩余字节直到超时。对每块加有界重试吸收瞬时抖动, 大幅降低截断概率;
        // 持续失败才中断, 让客户端按 Range 续传(原有恢复路径)。
        func fetchWithRetry(_ offset: Int64, _ length: Int64) async throws -> Data {
            var lastError: Error?
            for attempt in 0..<3 {
                do { return try await fetch(offset, length) }
                catch {
                    lastError = error
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 200_000_000) }
                }
            }
            throw lastError ?? URLError(.cannotLoadFromNetwork)
        }

        // 先取首块 —— 失败时还能改回 502(头部尚未发出)。
        let firstLen = min(streamChunkSize, max(0, total))
        let firstChunk = total > 0 ? try await fetchWithRetry(0, firstLen) : Data()

        let reason = [200: "OK", 206: "Partial Content", 403: "Forbidden",
                      404: "Not Found", 502: "Bad Gateway"][status] ?? "OK"
        var h = headers
        h["Content-Length"] = "\(total)"
        h["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        // 头部 + 首块一起发出。这之后失败都不能再改状态码,只能中断连接。
        var out = Data(head.utf8); out.append(firstChunk)
        do { try await sendAsync(conn, out) } catch { conn.cancel(); return }

        var sent = Int64(firstChunk.count)
        while sent < total {
            let len = min(streamChunkSize, total - sent)
            let chunk: Data
            do {
                chunk = try await fetchWithRetry(sent, len)
            } catch {
                // 重试仍失败, 头已发出无法再改状态码;中断让客户端按 Range 续传。
                break
            }
            if chunk.isEmpty { break }
            do { try await sendAsync(conn, chunk) } catch { break }
            sent += Int64(chunk.count)
        }
        conn.cancel()
    }

    /// 把一段数据写入连接并等待 send 完成(把回调式 send 包成 async)。
    private static func sendAsync(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    static func wifiIPv4() -> String? {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return nil }
        defer { freeifaddrs(addrList) }
        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if name == "en0", let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }
}
#endif
