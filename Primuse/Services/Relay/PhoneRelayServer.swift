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

    private var sourceManager: SourceManager?
    private weak var sourcesStore: SourcesStore?
    private weak var library: MusicLibrary?

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
                conn.start(queue: self?.queue ?? .global())
                self?.readHead(conn, buffer: Data())
            }
            l.start(queue: queue)
            listener = l
        } catch {
            plog("Relay: listener start failed — \(error)")
        }
    }

    private func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf.subdata(in: buf.startIndex..<end.lowerBound), as: UTF8.self)
                self.handle(conn, head: head)
            } else if error == nil, !complete, buf.count < 64 * 1024 {
                self.readHead(conn, buffer: buf)
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
            let (start, end) = Self.parseRange(req.range, total: total)
            do {
                let connector = await MainActor.run { manager.connector(for: source) }
                let data = try await connector.fetchRange(path: path, offset: start, length: end - start + 1)
                Self.respond(conn, status: 206, headers: [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(total)",
                ], body: data)
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
