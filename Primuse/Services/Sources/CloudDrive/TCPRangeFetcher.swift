import Foundation
import Network
import PrimuseKit
import Security

/// 用 `NWConnection` 走 TCP + HTTP/1.1 发 Range GET，从协议层绕开 HTTP/3(QUIC)。
///
/// 背景：iOS 的 `URLSession` 会对 OneDrive CDN(*.microsoftpersonalcontent.com)
/// 协商 HTTP/3。实测同一份代码、同一个文件：
///   - iOS  走 h3(QUIC)：每 1MB chunk 7~18s，约 100KB/s；
///   - macOS 走 h2(TCP) ：每 1MB chunk 0.3~0.8s，约 2MB/s。
/// OneDrive 的 QUIC 路径慢 20~30 倍，导致大文件逐 chunk 流式播放饿死(播 2 秒断)。
/// `URLSession` 无法可靠禁用 QUIC(Alt-Svc 缓存跨 session 共享，Apple DTS 确认无解)，
/// 所以这里直接用 `NWConnection`，TLS ALPN 只宣告 "http/1.1" —— 永远走 TCP，不给 QUIC 机会。
///
/// 连接复用：macOS 的 h2 之所以快，关键是**复用一条热连接**(TCP 慢启动只付一次)。
/// 早期实现每个 chunk 都 `Connection: close` 新建冷连接，吃满 TCP 慢启动，1MB 要 10~32s。
/// 现在改为**每个 host 维护一条 keep-alive 长连接、串行复用**：首 chunk 热身后，
/// 后续 chunk 在同一条已 ramp-up 的连接上跑，接近 macOS 的 ~2MB/s。
enum TCPRangeFetcher {
    enum FetchError: Error, LocalizedError {
        case badURL
        case connection(String)
        case timeout
        case http(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .badURL: return "TCPRangeFetcher: bad URL"
            case .connection(let m): return "TCPRangeFetcher: connection \(m)"
            case .timeout: return "TCPRangeFetcher: timeout"
            case .http(let c): return "TCPRangeFetcher: HTTP \(c)"
            case .malformedResponse: return "TCPRangeFetcher: malformed response"
            }
        }

        /// HTTP 状态码错误意味着连接本身是好的(响应已完整读完)，应原样上抛让
        /// 上层的 401/403/410→刷新直链 逻辑生效，且连接仍可复用、不应丢弃/重试。
        var isHTTPStatus: Bool {
            if case .http = self { return true }
            return false
        }
    }

    /// 语义同 `CloudDriveHelper.rangeRequest`：返回文件 `[offset, offset+length)` 区间的字节。
    /// - 206：响应体即该 slice，直接返回。
    /// - 200：服务端忽略了 Range 返回整文件，自行切窗口。
    ///
    /// 内部按 host 复用一条 keep-alive 长连接；同一 host 的请求串行执行。
    static func fetch(
        url: URL,
        offset: Int64,
        length: Int64,
        userAgent: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        guard let host = url.host else { throw FetchError.badURL }
        let rawPort = UInt16(exactly: url.port ?? 443) ?? 443
        let port = NWEndpoint.Port(rawValue: rawPort) ?? 443
        let endpoint = await TCPConnectionPool.shared.endpoint(host: host, port: port)
        return try await endpoint.fetch(
            url: url, offset: offset, length: length,
            userAgent: userAgent, timeoutSeconds: timeoutSeconds
        )
    }
}

/// 全局连接池：每个 `host:port` 对应一个 `TCPHostEndpoint`(各自持有一条长连接)。
private actor TCPConnectionPool {
    static let shared = TCPConnectionPool()
    private var endpoints: [String: TCPHostEndpoint] = [:]

    func endpoint(host: String, port: NWEndpoint.Port) -> TCPHostEndpoint {
        let key = "\(host):\(port.rawValue)"
        if let existing = endpoints[key] { return existing }
        let created = TCPHostEndpoint(host: host, port: port)
        endpoints[key] = created
        return created
    }
}

/// 一个 host 的串行长连接管理者。
///
/// actor 只保证**单步**互斥，在每个 `await` 处会被重入；HTTP/1.1 keep-alive 不支持
/// pipelining，必须保证「发请求 → 收完整响应」整段在一条连接上串行、不交错，所以这里
/// 用显式的异步互斥锁(`acquire`/`release`)把整个 `fetch` 串起来，而不是只靠 actor 隔离。
private actor TCPHostEndpoint {
    private let host: String
    private let port: NWEndpoint.Port

    /// 当前复用的连接；nil 表示尚未建立或已被丢弃。
    private var conn: PooledConnection?

    // 异步互斥锁：保证同一 host 同时只有一个 fetch 在跑。
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: NWEndpoint.Port) {
        self.host = host
        self.port = port
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // 被 release 唤醒时锁的所有权已直接移交给我们，locked 始终保持 true。
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    func fetch(
        url: URL,
        offset: Int64,
        length: Int64,
        userAgent: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        await acquire()
        defer { release() }

        // 优先复用既有活连接。复用失败(连接级错误，含 keep-alive 空闲被服务端关闭)→
        // 丢弃后用新连接重试一次，对上层透明。HTTP 状态错误(响应已完整)直接上抛、不重试。
        if let existing = conn, !existing.isDead {
            do {
                return try await runRequest(
                    on: existing, connectFirst: false,
                    url: url, offset: offset, length: length,
                    userAgent: userAgent, timeoutSeconds: timeoutSeconds
                )
            } catch let e as TCPRangeFetcher.FetchError where e.isHTTPStatus {
                throw e
            } catch {
                drop(existing)
                // 任务被取消(如 seek 时上层放弃该 chunk):不重试,直接上抛。
                if Task.isCancelled { throw error }
                plog("🔌 TCP reused conn broken(\(error.localizedDescription)) → rebuild host=\(host)")
                // 落到下面用新连接重试。
            }
        }

        try Task.checkCancellation()   // 取消时别再建新连接

        let fresh = PooledConnection(host: host, port: port)
        conn = fresh
        do {
            return try await runRequest(
                on: fresh, connectFirst: true,
                url: url, offset: offset, length: length,
                userAgent: userAgent, timeoutSeconds: timeoutSeconds
            )
        } catch let e as TCPRangeFetcher.FetchError where e.isHTTPStatus {
            // 连接是好的(状态码错误)，保留供后续复用。
            throw e
        } catch {
            drop(fresh)
            throw error
        }
    }

    private func drop(_ pooled: PooledConnection) {
        if conn === pooled { conn = nil }
        pooled.cancel()
    }

    /// 在一条连接上跑「(按需握手)→发请求→收完整响应」，整段带超时。
    /// 超时即取消该连接(状态已不确定，必须重建)，让挂起的收发回调以 cancelled 退出。
    private func runRequest(
        on pooled: PooledConnection,
        connectFirst: Bool,
        url: URL,
        offset: Int64,
        length: Int64,
        userAgent: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        let host = self.host
        // 任务被取消(如 seek)→ cancel 连接，唤醒挂在 continuation 上的收发子任务；
        // 否则 withThrowingTaskGroup 退出前要等所有子任务，收包子任务无人唤醒会永久挂起。
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    if connectFirst { try await pooled.connect() }
                    return try await pooled.request(
                        url: url, host: host, offset: offset,
                        length: length, userAgent: userAgent
                    )
                }
                group.addTask {
                    let nanoseconds = (max(0.1, timeoutSeconds) * 1_000_000_000)
                        .finiteUInt64(or: 100_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    pooled.cancel()  // 取消连接，唤醒上面挂起的握手/收发 continuation。
                    throw TCPRangeFetcher.FetchError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw TCPRangeFetcher.FetchError.malformedResponse
                }
                return result
            }
        } onCancel: {
            pooled.cancel()
        }
    }
}

/// 一条具体的 keep-alive 长连接。`@unchecked Sendable`：内部可变状态(死亡标记、ready
/// continuation、跨响应残留字节)全部由 `lock` 保护；同一时刻只有一个请求在用它(由
/// `TCPHostEndpoint` 的互斥锁保证)，body 收取天然串行。
private final class PooledConnection: @unchecked Sendable {
    let conn: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _dead = false

    // connect() 的 ready 握手 continuation；用「读出即清空」保证只 resume 一次。
    private var readyCont: CheckedContinuation<Void, Error>?

    // 上一个响应读过头、属于「下一个响应」的残留字节(keep-alive 下正常为空，仅作防御)。
    private var leftover = Data()

    init(host: String, port: NWEndpoint.Port) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        // 只宣告 http/1.1：不给 h2/h3 —— 强制 TCP + HTTP/1.1，从 ALPN 层杜绝 QUIC。
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls)
        self.conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        self.queue = DispatchQueue(label: "primuse.tcp.range")
    }

    var isDead: Bool {
        lock.lock(); defer { lock.unlock() }
        return _dead
    }

    private func markDead() {
        lock.lock(); _dead = true; lock.unlock()
    }

    func cancel() {
        markDead()
        conn.cancel()
    }

    /// 建连并等到 `.ready`。整条连接生命周期共用一个 stateUpdateHandler：握手期 resume
    /// ready continuation；之后任何 failed/cancelled/waiting 只标记死亡(下次复用前
    /// `isDead` 检查会跳过它)。`connect()` 对每个 PooledConnection 只调用一次。
    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            readyCont = cont
            lock.unlock()

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resolveReady(nil)
                case .failed(let err):
                    self.markDead()
                    self.resolveReady(err)
                case .cancelled:
                    self.markDead()
                    self.resolveReady(TCPRangeFetcher.FetchError.connection("cancelled"))
                case .waiting(let err):
                    // 无网络/被拒：不无限等，直接失败让上层兜底。
                    self.markDead()
                    self.resolveReady(err)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// 读出并清空 readyCont，保证 ready continuation 只 resume 一次(状态机会多次回调)。
    private func resolveReady(_ error: Error?) {
        lock.lock()
        let cont = readyCont
        readyCont = nil
        lock.unlock()
        guard let cont else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// 发一个 Range 请求并读取**整个**响应；连接保持打开供下次复用。
    func request(
        url: URL, host: String,
        offset: Int64, length: Int64, userAgent: String?
    ) async throws -> Data {
        // 用 percent-encoded 的 path/query 原样拼请求行：`URL.path`/`URL.query` 返回的是
        // 解码后的字符串，含 %20、中文等需编码字符的直链会发出非法报文或与服务端按编码后
        // URL 计算的签名不符而 403。
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = comps?.percentEncodedPath ?? url.path
        var path = encodedPath.isEmpty ? "/" : encodedPath
        if let q = comps?.percentEncodedQuery ?? url.query, !q.isEmpty { path += "?" + q }
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            throw TCPRangeFetcher.FetchError.malformedResponse
        }
        var head = "GET \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Range: \(rangeHeader)\r\n"
        if let ua = userAgent { head += "User-Agent: \(ua)\r\n" }
        head += "Accept: */*\r\n"
        head += "Accept-Encoding: identity\r\n"
        head += "Connection: keep-alive\r\n"
        head += "\r\n"

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(head.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }

        let (status, body) = try await receiveResponse()

        switch status {
        case 206:
            return body
        case 200:
            // 服务端忽略 Range 返回整文件，自行切窗口(与 CloudDriveHelper.rangeRequest 200 分支一致)。
            let total = Int64(body.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: actualOffset, length: length) else {
                return Data()
            }
            let upper = min(requestedEnd, total)
            return body.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw TCPRangeFetcher.FetchError.http(status)
        }
    }

    // MARK: - 响应读取(keep-alive 必须精确按帧读，留下干净的连接给下一个请求)

    /// 读满一个完整 HTTP/1.1 响应。优先按 Content-Length 精确收满(读到 body 末尾即停，
    /// 多余字节作为下个响应的 leftover 暂存)；transfer-encoding: chunked 则读到结束块。
    /// 二者皆无(until-close 帧)时只能读到 EOF 并标记连接不可复用。
    private func receiveResponse() async throws -> (Int, Data) {
        let headerSep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var raw = takeLeftover()
        var headerEnd: Int? = nil      // body 起始下标(\r\n\r\n 之后)
        var contentLength: Int? = nil
        var isChunked = false
        var status: Int? = nil

        while true {
            let (chunk, isComplete) = try await receiveOnce()
            if let chunk, !chunk.isEmpty { raw.append(chunk) }

            if headerEnd == nil, let r = raw.range(of: headerSep) {
                headerEnd = r.upperBound
                let headerData = raw.subdata(in: raw.startIndex..<r.lowerBound)
                let parsed = try parseHeaders(headerData)
                status = parsed.status
                contentLength = parsed.contentLength
                isChunked = parsed.isChunked
            }

            // 收齐则立即返回(不能再 receiveOnce，否则会等一个永不到来的字节)。
            if let he = headerEnd, let sc = status {
                if isChunked {
                    if let bodyEnd = chunkedBodyEnd(raw, from: he) {
                        let body = Self.dechunk(raw.subdata(in: he..<bodyEnd))
                        stashLeftover(raw.subdata(in: bodyEnd..<raw.endIndex))
                        return (sc, body)
                    }
                } else if let cl = contentLength {
                    if raw.count - he >= cl {
                        let bodyEnd = he + cl
                        let body = raw.subdata(in: he..<bodyEnd)
                        stashLeftover(raw.subdata(in: bodyEnd..<raw.endIndex))
                        return (sc, body)
                    }
                }
            }

            if isComplete {
                // 服务端关闭了连接：标记死亡(不可复用)，尽力给出已有 body。
                markDead()
                guard let he = headerEnd, let sc = status else {
                    throw TCPRangeFetcher.FetchError.malformedResponse
                }
                if isChunked {
                    return (sc, Self.dechunk(raw.subdata(in: he..<raw.endIndex)))
                }
                if let cl = contentLength, raw.count - he < cl {
                    // Content-Length 未读满就 EOF：body 被截断，按连接错误处理。
                    throw TCPRangeFetcher.FetchError.connection("truncated body \(raw.count - he)/\(cl)")
                }
                // until-close 帧：EOF 即完整。
                return (sc, raw.subdata(in: he..<raw.endIndex))
            }
        }
    }

    private func receiveOnce() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data.map { Data($0) }, isComplete))
            }
        }
    }

    private func takeLeftover() -> Data {
        lock.lock(); defer { lock.unlock() }
        let l = leftover
        leftover = Data()
        return l
    }

    private func stashLeftover(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        leftover = d
    }

    // MARK: - HTTP/1.1 解析

    private func parseHeaders(_ headerData: Data) throws -> (status: Int, contentLength: Int?, isChunked: Bool) {
        guard let headerStr = String(data: headerData, encoding: .isoLatin1) ?? String(data: headerData, encoding: .utf8) else {
            throw TCPRangeFetcher.FetchError.malformedResponse
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw TCPRangeFetcher.FetchError.malformedResponse }
        // "HTTP/1.1 206 Partial Content"
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw TCPRangeFetcher.FetchError.malformedResponse
        }
        var cl: Int? = nil
        var chunked = false
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                guard let parsedLength = Int(v), parsedLength >= 0 else {
                    throw TCPRangeFetcher.FetchError.malformedResponse
                }
                cl = parsedLength
            } else if lower.hasPrefix("transfer-encoding:") && lower.contains("chunked") {
                chunked = true
            }
        }
        return (status, cl, chunked)
    }

    /// 在 chunked body 里找结束位置(终止块 `0\r\n...\r\n\r\n` 之后)；未收全返回 nil。
    private func chunkedBodyEnd(_ data: Data, from start: Int) -> Int? {
        var i = start
        let crlf = Data([0x0D, 0x0A])
        let dblCrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while i < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { return nil }
            let sizeLine = data.subdata(in: i..<lineEnd.lowerBound)
            guard let sizeStr = String(data: sizeLine, encoding: .ascii)?
                .split(separator: ";").first.map(String.init),
                  let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { return nil }
            if size == 0 {
                // 终止块：到最终空行(可能带 trailer)为止。
                if let term = data.range(of: dblCrlf, in: i..<data.endIndex) {
                    return term.upperBound
                }
                return nil
            }
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex),
                  chunkEnd <= data.endIndex,
                  data.distance(from: chunkStart, to: chunkEnd) == size else { return nil }
            // 跳过 chunk 数据后的 \r\n
            guard let next = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) else { return nil }
            i = next
        }
        return nil
    }

    /// 解 HTTP/1.1 chunked transfer-encoding。
    private static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data([0x0D, 0x0A])
        while i < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { break }
            let sizeLine = data.subdata(in: i..<lineEnd.lowerBound)
            guard let sizeStr = String(data: sizeLine, encoding: .ascii)?
                .split(separator: ";").first.map(String.init),
                  let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { break }
            if size == 0 { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data.subdata(in: chunkStart..<chunkEnd))
            // 跳过 chunk 后的 \r\n
            i = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
