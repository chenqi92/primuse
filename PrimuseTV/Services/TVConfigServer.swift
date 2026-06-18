#if os(tvOS)
import Foundation
import Network
import PrimuseKit

/// Apple TV 局域网「扫码直传」接收端。绕开 iCloud:TV 起一个一次性 HTTP 监听,二维码
/// 带上 `host:port` + 一次性 AES 密钥;iPhone 扫码后把整库 / 源 / 凭据 AES-GCM 加密后
/// `POST /config` 过来,TV 解密落盘 + reload。与 `PhoneRelayServer`(TV→phone 中继拉流)
/// 方向相反、互补:这条解决「源配置怎么过来」,那条解决「字节流怎么拉回」。
///
/// 安全:① 载荷必须用二维码里的一次性密钥 AES-GCM 解开,否则 403(密钥即鉴权);
/// ② body 体积上限防 LAN 端打爆内存;③ 半开连接 idle 超时 + 并发上限防 slow-loris。
final class TVConfigServer: @unchecked Sendable {
    /// 解密成功的载荷(回调内自行跳 MainActor,由 TVStore 落盘 + reload)。
    var onReceive: (@Sendable (LANSyncPayload) -> Void)?
    /// 端点就绪(端口在 listener `.ready` 时才分配)。用于刷新二维码内容。
    var onEndpointReady: (@Sendable (LANPairLink?) -> Void)?

    private let queue = DispatchQueue(label: "com.welape.primuse.tvconfig")
    private var listener: NWListener?
    private var key = LANSyncCrypto.randomKey()
    private var pairCode = LANPairLink.randomPairCode()
    private var boundPort: UInt16?

    /// body 上限 32MB(整库快照通常几百 KB~数 MB,留足余量),超出直接拒。
    private static let maxBodyBytes = 32 * 1024 * 1024
    private static let headerTimeout: TimeInterval = 15
    private static let bodyTimeout: TimeInterval = 30
    private static let maxConnections = 8
    private var activeConnections = 0

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.boundPort = nil
        }
    }

    /// 当前配对端点(host+port+key)。未运行 / 无可用网络时 nil。
    func endpoint() -> LANPairLink? {
        guard let port = boundPort, let ip = Self.localIPv4() else { return nil }
        return LANPairLink(host: ip, port: Int(port), key: key, pairCode: pairCode)
    }

    // MARK: - Listener

    private func startListener() {
        guard listener == nil else {
            emitEndpoint()
            return
        }
        // 每次启动换一把新密钥(一次性配对)。
        rotatePairingSecret()
        do {
            let l = try NWListener(using: .tcp)
            l.stateUpdateHandler = { [weak self, weak l] state in
                if case .ready = state {
                    self?.boundPort = l?.port?.rawValue
                    self?.emitEndpoint()
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                self.acceptConnection(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            plog("TVConfigServer: listener start failed — \(error)")
        }
    }

    private func emitEndpoint() {
        onEndpointReady?(endpoint())
    }

    private func acceptConnection(_ conn: NWConnection) {
        guard activeConnections < Self.maxConnections else { conn.cancel(); return }
        activeConnections += 1
        let requestTimer = DispatchSource.makeTimerSource(queue: queue)
        requestTimer.schedule(deadline: .now() + Self.headerTimeout)
        requestTimer.setEventHandler { [weak conn] in conn?.cancel() }
        requestTimer.resume()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                requestTimer.cancel()
                if let self, self.activeConnections > 0 { self.activeConnections -= 1 }
            default:
                break
            }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data(), requestTimer: requestTimer)
    }

    /// 读到 `\r\n\r\n` 为止凑齐请求头,解析出 Content-Length 后续读 body。
    private func readRequest(_ conn: NWConnection, buffer: Data, requestTimer: DispatchSourceTimer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                requestTimer.schedule(deadline: .now() + Self.bodyTimeout)
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                let already = Data(buf[end.upperBound...])
                guard let req = Self.parseRequest(head), req.method == "POST", req.path == "/config",
                      let len = req.contentLength, len > 0, len <= Self.maxBodyBytes else {
                    Self.respond(conn, status: 400); return
                }
                guard req.headers["x-primuse-pair-code"] == self.pairCode else {
                    Self.respond(conn, status: 403); return
                }
                self.readBody(conn, body: already, need: len)
            } else if error == nil, !complete, buf.count < 64 * 1024 {
                self.readRequest(conn, buffer: buf, requestTimer: requestTimer)
            } else {
                conn.cancel()
            }
        }
    }

    private func readBody(_ conn: NWConnection, body: Data, need: Int) {
        if body.count >= need {
            process(conn, body: Data(body.prefix(need)))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var b = body
            if let data { b.append(data) }
            if b.count >= need {
                self.process(conn, body: Data(b.prefix(need)))
            } else if error == nil, !complete {
                self.readBody(conn, body: b, need: need)
            } else {
                conn.cancel()
            }
        }
    }

    /// 用一次性密钥 AES-GCM 解密 → 解码 LANSyncPayload → 主线程回调落盘。
    private func process(_ conn: NWConnection, body: Data) {
        guard let plain = LANSyncCrypto.open(body, key: key),
              let payload = LANSyncPayload.decode(plain) else {
            plog("TVConfigServer: decrypt/decode failed (\(body.count)B)")
            Self.respond(conn, status: 403)
            return
        }
        plog("TVConfigServer: received payload (lib=\(payload.libraryGz?.count ?? 0)B src=\(payload.sourcesGz?.count ?? 0)B creds=\(payload.credentials?.entries.count ?? 0))")
        // 成功接收后立即换 key + 短码,让二维码里的旧密钥不可复用。
        rotatePairingSecret()
        emitEndpoint()
        onReceive?(payload)
        Self.respond(conn, status: 200)
    }

    // MARK: - 纯函数 / 工具

    private func rotatePairingSecret() {
        key = LANSyncCrypto.randomKey()
        pairCode = LANPairLink.randomPairCode()
    }

    static func parseRequest(_ head: String) -> (method: String, path: String, contentLength: Int?, headers: [String: String])? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let comp = URLComponents(string: String(parts[1])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let len = headers["content-length"].flatMap(Int.init)
        return (String(parts[0]), comp.path, len, headers)
    }

    private static func respond(_ conn: NWConnection, status: Int) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 本机局域网 IPv4。Apple TV 常走有线网,接口名未必是 Wi-Fi 的 en0,故扫所有 `en*`
    /// 非 loopback、已 UP 的 IPv4,优先 en0,否则取首个可用(有线/无线都覆盖)。
    static func localIPv4() -> String? {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return nil }
        defer { freeifaddrs(addrList) }
        var candidates: [(name: String, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            let name = String(cString: ifa.ifa_name)
            if (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0, name.hasPrefix("en"),
               let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    candidates.append((name, String(cString: host)))
                }
            }
            ptr = ifa.ifa_next
        }
        return candidates.first(where: { $0.name == "en0" })?.ip ?? candidates.first?.ip
    }
}
#endif
