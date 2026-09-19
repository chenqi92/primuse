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
    /// 分段直传的一段,已解密校验。
    enum StageRequest: Sendable {
        case sources(LANSyncPayload)
        case library(LANSyncPayload)
        case artwork(LANArtworkBatch, index: Int, count: Int)
        case finish
    }

    /// 请求体接收进度。整包(旧版 iPhone)按 `.library` 报。
    struct ReceiveProgress: Sendable {
        let stage: LANTransferStage
        let receivedBytes: Int
        let totalBytes: Int
        let batchIndex: Int?
        let batchCount: Int?
        /// 与 `onStage` / `onReceive` 收到的编号对应,界面据此认出迟到的进度。
        let requestSerial: Int
    }

    private enum Route {
        case legacy
        case staged(LANTransferStage, batch: (index: Int, count: Int)?)

        var progressStage: LANTransferStage? {
            switch self {
            case .legacy: return .library
            case .staged(.finish, _): return nil
            case .staged(let stage, _): return stage
            }
        }
    }

    /// 旧版 iPhone 的整包及其请求编号。只有回调确认快照与凭据均已持久化，HTTP 才返回 200。
    var onReceive: (@Sendable (LANSyncPayload, Int) async -> Bool)?
    /// 分段直传的一段及其请求编号。同样只在回调确认落盘后返回 200。
    var onStage: (@Sendable (StageRequest, Int) async -> Bool)?
    /// 请求体接收进度,在服务队列上回调。
    var onReceiveProgress: (@Sendable (ReceiveProgress) -> Void)?
    /// 分段会话结束:`true` 为 iPhone 发来收尾,`false` 为闲置过期。二维码此时已换新。
    var onSessionEnded: (@Sendable (Bool) -> Void)?
    /// 端点就绪(端口在 listener `.ready` 时才分配)。用于刷新二维码内容。
    var onEndpointReady: (@Sendable (LANPairLink?) -> Void)?

    private let queue = DispatchQueue(label: "com.welape.primuse.tvconfig")
    private var listener: NWListener?
    private var key = LANSyncCrypto.randomKey()
    private var pairCode = LANPairLink.randomPairCode()
    private var boundPort: UInt16?
    /// 分段会话的闲置计时,只在没有分段请求进行中时走;到期即作废本次密钥。
    private var sessionTimer: DispatchSourceTimer?
    private var sessionActive = false
    private var stagedConnections: Set<ObjectIdentifier> = []
    private var requestSerial = 0
    /// 每次 `stop()` 加一。停止前收下的请求晚些完成时,不能去轮换新二维码的密钥或重新计时。
    private var generation = 0

    /// body 上限与 iPhone 端共用;带封面的大曲库由发送端缩减封面装进来,超出直接拒。
    private static let maxBodyBytes = LANTransferSizePolicy.maximumSealedBytes
    private static let headerTimeout: TimeInterval = 15
    /// 请求体的闲置超时:每收到一块就重新计时,收完即取消,之后的落盘不受它限制。
    private static let bodyIdleTimeout: TimeInterval = 30
    /// 分段之间 iPhone 要准备曲库、收集封面,留足时间;超过则密钥作废,需重新扫码。
    private static let sessionIdleTimeout: TimeInterval = 10 * 60
    private static let maxConnections = 8
    private var activeConnections = 0

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.boundPort = nil
            self.activeConnections = 0
            self.generation += 1
            self.sessionActive = false
            self.stagedConnections.removeAll()
            self.cancelSessionTimer()
            self.rotatePairingSecret()
            self.onEndpointReady?(nil)
        }
    }

    /// 当前配对端点(host+port+key)。未运行 / 无可用网络时 nil。
    func endpoint() -> LANPairLink? {
        guard let port = boundPort, let ip = Self.localIPv4() else { return nil }
        return LANPairLink(host: ip, port: Int(port), key: key, pairCode: pairCode,
                           protocolVersion: LANPairLink.stagedProtocolVersion)
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
        let connectionID = ObjectIdentifier(conn)
        let connectionGeneration = generation
        let requestTimer = DispatchSource.makeTimerSource(queue: queue)
        requestTimer.schedule(deadline: .now() + Self.headerTimeout)
        requestTimer.setEventHandler { [weak conn] in conn?.cancel() }
        requestTimer.resume()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                requestTimer.cancel()
                guard let self else { return }
                if self.activeConnections > 0 { self.activeConnections -= 1 }
                self.stagedRequestEnded(connectionID, generation: connectionGeneration)
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
                requestTimer.schedule(deadline: .now() + Self.bodyIdleTimeout)
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                let already = Data(buf[end.upperBound...])
                guard let req = Self.parseRequest(head), req.method == "POST",
                      let route = Self.route(path: req.path, headers: req.headers),
                      let len = req.contentLength, len > 0, len <= Self.maxBodyBytes else {
                    Self.respond(conn, status: 400); return
                }
                guard req.headers["x-primuse-pair-code"] == self.pairCode else {
                    Self.respond(conn, status: 403); return
                }
                self.requestSerial += 1
                let serial = self.requestSerial
                if case .staged = route { self.stagedRequestBegan(ObjectIdentifier(conn)) }
                self.reportProgress(route, serial: serial, received: 0, total: len)
                self.readBody(conn, body: already, need: len, route: route, serial: serial,
                              requestTimer: requestTimer, lastReported: 0)
            } else if error == nil, !complete, buf.count < 64 * 1024 {
                self.readRequest(conn, buffer: buf, requestTimer: requestTimer)
            } else {
                conn.cancel()
            }
        }
    }

    private func readBody(_ conn: NWConnection, body: Data, need: Int, route: Route, serial: Int,
                          requestTimer: DispatchSourceTimer, lastReported: Int) {
        if body.count >= need {
            requestTimer.cancel()
            process(conn, body: Data(body.prefix(need)), route: route, serial: serial)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var b = body
            if let data { b.append(data) }
            if b.count >= need {
                requestTimer.cancel()
                self.process(conn, body: Data(b.prefix(need)), route: route, serial: serial)
            } else if error == nil, !complete {
                requestTimer.schedule(deadline: .now() + Self.bodyIdleTimeout)
                // 每 2% 报一次;最后一块不报,收完就进入落盘状态。
                var reported = lastReported
                if b.count - reported >= max(64 * 1024, need / 50) {
                    reported = b.count
                    self.reportProgress(route, serial: serial, received: b.count, total: need)
                }
                self.readBody(conn, body: b, need: need, route: route, serial: serial,
                              requestTimer: requestTimer, lastReported: reported)
            } else {
                conn.cancel()
            }
        }
    }

    private func reportProgress(_ route: Route, serial: Int, received: Int, total: Int) {
        guard let stage = route.progressStage else { return }
        var batch: (index: Int, count: Int)?
        if case .staged(_, let value) = route { batch = value }
        onReceiveProgress?(ReceiveProgress(stage: stage, receivedBytes: received, totalBytes: total,
                                           batchIndex: batch?.index, batchCount: batch?.count,
                                           requestSerial: serial))
    }

    /// 用一次性密钥 AES-GCM 解密后按路径分派,等待回调完成持久化再回应。
    private func process(_ conn: NWConnection, body: Data, route: Route, serial: Int) {
        guard let plain = LANSyncCrypto.open(body, key: key) else {
            plog("TVConfigServer: decrypt failed (\(body.count)B)")
            Self.respond(conn, status: 403)
            return
        }
        switch route {
        case .legacy:
            processLegacy(conn, plain: plain, serial: serial)
        case .staged(let stage, let batch):
            processStage(conn, stage: stage, batch: batch, plain: plain, serial: serial)
        }
    }

    private func processLegacy(_ conn: NWConnection, plain: Data, serial: Int) {
        guard let payload = LANSyncPayload.decode(plain) else {
            plog("TVConfigServer: decode failed (\(plain.count)B)")
            Self.respond(conn, status: 403)
            return
        }
        guard payload.isCompleteForTransfer else {
            plog("TVConfigServer: rejected incomplete payload")
            Self.respond(conn, status: 400)
            return
        }
        plog("TVConfigServer: received payload (lib=\(payload.libraryGz?.count ?? 0)B src=\(payload.sourcesGz?.count ?? 0)B creds=\(payload.credentials?.entries.count ?? 0))")
        guard let onReceive else {
            Self.respond(conn, status: 503)
            return
        }
        let requestGeneration = generation
        Task { [weak self] in
            let persisted = await onReceive(payload, serial)
            guard let self else {
                conn.cancel()
                return
            }
            self.queue.async {
                // 持久化成功才消费一次性密钥；失败时保留当前二维码，允许手机重试。
                if persisted, requestGeneration == self.generation {
                    self.rotatePairingSecret()
                    self.emitEndpoint()
                }
                Self.respond(conn, status: persisted ? 200 : 500)
            }
        }
    }

    private func processStage(_ conn: NWConnection, stage: LANTransferStage,
                              batch: (index: Int, count: Int)?, plain: Data, serial: Int) {
        let request: StageRequest
        switch stage {
        case .sources:
            guard let payload = LANSyncPayload.decode(plain), payload.isCompleteSourcesStage else {
                plog("TVConfigServer: rejected sources stage (\(plain.count)B)")
                Self.respond(conn, status: 400); return
            }
            request = .sources(payload)
        case .library:
            guard let payload = LANSyncPayload.decode(plain), payload.isCompleteLibraryStage else {
                plog("TVConfigServer: rejected library stage (\(plain.count)B)")
                Self.respond(conn, status: 400); return
            }
            request = .library(payload)
        case .artwork:
            guard let artwork = LANArtworkBatch.decode(plain), let batch else {
                plog("TVConfigServer: rejected artwork batch (\(plain.count)B)")
                Self.respond(conn, status: 400); return
            }
            request = .artwork(artwork, index: batch.index, count: batch.count)
        case .finish:
            request = .finish
        }
        plog("TVConfigServer: received \(stage.rawValue) stage (\(plain.count)B)")
        guard let onStage else {
            Self.respond(conn, status: 503)
            return
        }
        let requestGeneration = generation
        Task { [weak self] in
            let persisted = await onStage(request, serial)
            guard let self else {
                conn.cancel()
                return
            }
            self.queue.async {
                // 收尾才消费密钥;中途失败保留当前二维码,手机可以接着发。
                if persisted, stage == .finish, requestGeneration == self.generation {
                    self.endSession(completed: true)
                }
                Self.respond(conn, status: persisted ? 200 : 500)
            }
        }
    }

    // MARK: - 分段会话

    /// 分段请求进行中(包括 TV 导入曲库那段时间)不计闲置;请求结束后才开始倒数。
    private func stagedRequestBegan(_ connection: ObjectIdentifier) {
        sessionActive = true
        stagedConnections.insert(connection)
        cancelSessionTimer()
    }

    private func stagedRequestEnded(_ connection: ObjectIdentifier, generation connectionGeneration: Int) {
        guard stagedConnections.remove(connection) != nil,
              connectionGeneration == generation,
              sessionActive,
              stagedConnections.isEmpty else { return }
        armSessionTimer()
    }

    private func endSession(completed: Bool) {
        sessionActive = false
        cancelSessionTimer()
        rotatePairingSecret()
        emitEndpoint()
        onSessionEnded?(completed)
    }

    private func armSessionTimer() {
        cancelSessionTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.sessionIdleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionActive, self.stagedConnections.isEmpty else { return }
            self.endSession(completed: false)
        }
        timer.resume()
        sessionTimer = timer
    }

    private func cancelSessionTimer() {
        sessionTimer?.cancel()
        sessionTimer = nil
    }

    // MARK: - 纯函数 / 工具

    private func rotatePairingSecret() {
        key = LANSyncCrypto.randomKey()
        pairCode = LANPairLink.randomPairCode()
    }

    private static func route(path: String, headers: [String: String]) -> Route? {
        if path == "/config" { return .legacy }
        guard let stage = LANTransferStage(path: path) else { return nil }
        guard stage == .artwork else { return .staged(stage, batch: nil) }
        guard let batch = LANArtworkBatchPosition(header: headers["x-primuse-batch"]) else { return nil }
        return .staged(stage, batch: (batch.index, batch.count))
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
        let reason = [
            200: "OK",
            400: "Bad Request",
            403: "Forbidden",
            500: "Internal Server Error",
            503: "Service Unavailable",
        ][status] ?? "Error"
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
                    let terminator = host.firstIndex(of: 0) ?? host.endIndex
                    let bytes = host[..<terminator].map { UInt8(bitPattern: $0) }
                    candidates.append((name, String(decoding: bytes, as: UTF8.self)))
                }
            }
            ptr = ifa.ifa_next
        }
        return candidates.first(where: { $0.name == "en0" })?.ip ?? candidates.first?.ip
    }
}
#endif
