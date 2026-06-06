import Foundation
import Network
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
    }

    /// 语义同 `CloudDriveHelper.rangeRequest`：返回文件 `[offset, offset+length)` 区间的字节。
    /// - 206：响应体即该 slice，直接返回。
    /// - 200：服务端忽略了 Range 返回整文件，自行切窗口。
    static func fetch(
        url: URL,
        offset: Int64,
        length: Int64,
        userAgent: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        guard let host = url.host else { throw FetchError.badURL }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? 443

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await rawFetch(
                    url: url, host: host, port: port,
                    offset: offset, length: length, userAgent: userAgent
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw FetchError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw FetchError.malformedResponse }
            return result
        }
    }

    private static func rawFetch(
        url: URL, host: String, port: NWEndpoint.Port,
        offset: Int64, length: Int64, userAgent: String?
    ) async throws -> Data {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        // 只宣告 http/1.1：不给 h2/h3 —— 强制 TCP + HTTP/1.1，从 ALPN 层杜绝 QUIC。
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        let queue = DispatchQueue(label: "primuse.tcp.range")

        // 整个流程包在一个取消处理器里：超时/上层取消时 conn.cancel() 会让挂起的
        // ready/send/receive 回调以 cancelled 错误返回，continuation 随之 resume、栈
        // 正常退栈，defer 拆连接，绝不泄漏。
        return try await withTaskCancellationHandler {
            defer {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }

            // 1) 等连接 ready(状态机可能多次回调，用 once 守卫保证 continuation 只 resume 一次)。
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumed = ResumeOnce()
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.tryResume() { cont.resume() }
                    case .failed(let err):
                        if resumed.tryResume() { cont.resume(throwing: err) }
                    case .cancelled:
                        if resumed.tryResume() { cont.resume(throwing: FetchError.connection("cancelled")) }
                    case .waiting(let err):
                        // 无网络/被拒：不无限等，直接失败让上层兜底。
                        if resumed.tryResume() { cont.resume(throwing: err) }
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
            }

            // 2) 发请求。Connection: close —— 服务端发完 body 即关连接，读到 EOF 就是完整响应，省去精确 Content-Length 解析。
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query, !q.isEmpty { path += "?" + q }
            let rangeHeader = offset < 0 ? "bytes=\(offset)" : "bytes=\(offset)-\(offset + length - 1)"
            var head = "GET \(path) HTTP/1.1\r\n"
            head += "Host: \(host)\r\n"
            head += "Range: \(rangeHeader)\r\n"
            if let ua = userAgent { head += "User-Agent: \(ua)\r\n" }
            head += "Accept: */*\r\n"
            head += "Accept-Encoding: identity\r\n"
            head += "Connection: close\r\n"
            head += "\r\n"

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: Data(head.utf8), completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }

            // 3) 读到 EOF。
            var raw = Data()
            while true {
                let (chunk, isComplete) = try await receiveOnce(conn)
                if let chunk, !chunk.isEmpty { raw.append(chunk) }
                if isComplete { break }
            }

            return try parse(raw, offset: offset, length: length)
        } onCancel: {
            conn.cancel()
        }
    }

    private static func receiveOnce(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data.map { Data($0) }, isComplete))
            }
        }
    }

    /// 解析 HTTP/1.1 响应：拆 header/body、读状态码、按需 de-chunk、按需对 200 切窗口。
    private static func parse(_ raw: Data, offset: Int64, length: Int64) throws -> Data {
        // 找 header 与 body 分界 \r\n\r\n
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = raw.range(of: sep) else { throw FetchError.malformedResponse }
        let headerData = raw.subdata(in: raw.startIndex..<r.lowerBound)
        var body = raw.subdata(in: r.upperBound..<raw.endIndex)

        guard let headerStr = String(data: headerData, encoding: .isoLatin1) ?? String(data: headerData, encoding: .utf8) else {
            throw FetchError.malformedResponse
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw FetchError.malformedResponse }
        // "HTTP/1.1 206 Partial Content"
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw FetchError.malformedResponse
        }

        let lowerHeaders = lines.dropFirst().map { $0.lowercased() }
        let isChunked = lowerHeaders.contains { $0.hasPrefix("transfer-encoding:") && $0.contains("chunked") }
        if isChunked {
            body = dechunk(body)
        }

        switch status {
        case 206:
            return body
        case 200:
            // 服务端忽略 Range 返回整文件，自行切窗口(与 CloudDriveHelper.rangeRequest 200 分支一致)。
            let total = Int64(body.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            let upper = min(actualOffset + length, total)
            return body.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw FetchError.http(status)
        }
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
                  let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
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

/// 保证一个 continuation 只被 resume 一次(NWConnection 状态机会多次回调)。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
