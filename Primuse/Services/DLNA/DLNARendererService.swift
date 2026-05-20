import Foundation
import Network
import OSLog
import UIKit
import PrimuseKit

private let dlnaLog = Logger(subsystem: "com.welape.yuanyin", category: "DLNA")

/// 把猿音宣告成局域网里的 UPnP/AV MediaRenderer ── 别的设备 (VLC / Synology
/// Audio Station / Plex / Hi-Fi Cast 等控制点) 可以发现这台手机, 把音乐
/// URL 推过来, 我们就播。
///
/// 实现范围 (MVP, 跟主流控制点已能互通):
/// - **SSDP**: 监听 239.255.255.250:1900 的 UDP multicast, 回 M-SEARCH; 周期
///   广播 alive。
/// - **HTTP**: 监听 TCP 49152, 提供 device.xml / 服务 SCPD xml / 控制 endpoint。
/// - **AVTransport 服务**: 实现 SetAVTransportURI / SetNextAVTransportURI /
///   Play / Pause / Stop / Next / Seek / 状态查询; DIDL-Lite metadata 只读
///   dc:title / upnp:artist (不读 cover, 因为推过来的 URL 一般是 HTTP stream,
///   跟我们自己的 source 不同源, 解 ID3 太重)。
/// - **RenderingControl**: 支持 Master channel 的 Get/Set Volume 与
///   Get/Set Mute, 并通过 GENA LastChange 同步给控制点。
///
/// 主流程: 控制点 → SetAVTransportURI(url, didl) → 我们 parse out url + title
/// → 创建一个临时 Song (sourceID = "dlna",  filePath = url, 用 DIDL 里的标题)
/// → 喂给 AudioPlayerService.play(song:from:)。
@MainActor
@Observable
final class DLNARendererService {
    /// UI 用的开关。打开时 start() 启动 SSDP + HTTP; 关上时 stop()。
    /// 内部独立持久, 跟 UserDefaults 解耦, 由 Settings 那边 mirror。
    private(set) var isRunning = false
    /// 最近一条状态行,给 settings 显示 "等待发现" / "正在播放 xx" / "错误: xx"。
    private(set) var statusText: String = ""
    /// 最近 80 条事件 ── 给 Settings 调试面板按时间倒序展示。包含 M-SEARCH 命中、
    /// SOAP 控制调用、GENA 订阅生命周期。环形覆盖, 太老的事件丢掉。
    private(set) var recentEvents: [DebugEvent] = []
    /// 最近接触过本机 renderer 的控制端。DLNA 不保证控制点会暴露设备昵称,
    /// 所以优先用 User-Agent 识别应用,否则回退到来源 IP。
    private(set) var connectedDevices: [ConnectedDevice] = []
    private static let maxRecentEvents = 80
    private static let maxConnectedDevices = 8

    struct DebugEvent: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let kind: Kind
        let detail: String
        enum Kind: Sendable { case discovery, control, event, error }
    }

    struct ConnectedDevice: Identifiable, Sendable {
        let id: String
        var name: String
        var address: String
        var clientDescription: String?
        var lastSeen: Date
        var isCasting: Bool
    }

    private func logEvent(_ kind: DebugEvent.Kind, _ detail: String) {
        switch kind {
        case .discovery:
            dlnaLog.info("discovery: \(detail, privacy: .public)")
        case .control:
            dlnaLog.info("control: \(detail, privacy: .public)")
        case .event:
            dlnaLog.info("event: \(detail, privacy: .public)")
        case .error:
            dlnaLog.error("error: \(detail, privacy: .public)")
        }
        recentEvents.insert(
            DebugEvent(timestamp: Date(), kind: kind, detail: detail),
            at: 0
        )
        if recentEvents.count > Self.maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - Self.maxRecentEvents)
        }
    }

    private var ssdpListener: NWListener?
    private var httpListener: NWListener?
    /// SSDP multicast 组,负责接收发到 239.255.255.250:1900 的 M-SEARCH
    /// (大多数控制点用 multicast search) 以及主动发 NOTIFY alive 广播。
    private var ssdpMulticast: NWConnectionGroup?
    /// NOTIFY alive 周期任务。`ssdp:byebye` 在 stop() 里同步发掉。
    private var notifyTask: Task<Void, Never>?

    /// GENA 订阅表 ── 控制点 SUBSCRIBE /event/<svc> 时这里加一条;
    /// 状态变 (TransportState / Volume / Mute 等) 时按 service 路由 NOTIFY。
    /// 简化掉 SEQ 字段递增 (用 monotonic counter), TIMEOUT 用固定 1800s。
    private struct Subscription {
        let sid: String
        let service: String  // "AVTransport" | "RenderingControl"
        let callbackURL: URL
        var seq: Int = 0
        var expiresAt: Date
    }
    private var subscriptions: [String: Subscription] = [:]
    /// Player / volume 观察器, 状态变时触发 NOTIFY。在 start() 里 install。
    private var playerObservationToken: Task<Void, Never>?
    /// 自分配的设备 UUID,持久化到 UserDefaults 让重启后控制点不会把我们当
    /// 成"新设备"重新订阅 (有些控制点会缓存 UUID)。
    private let deviceUUID: String

    /// 我们暴露的友好名称 ── 默认 "猿音 · <设备名>"。
    private let friendlyName: String

    /// 主 player 引用,SetAVTransportURI 时把 URL 推过去。
    private let player: AudioPlayerService
    /// UPnP RenderingControl 的 mute 是独立状态,不能简单等同于 volume=0。
    private var rendererMuted = false
    private var lastNonMutedVolume: Float = 0.6
    private struct TransportItem: Sendable {
        let uri: String
        let metadata: String
        let title: String
        let artist: String?
        let url: URL
    }
    private var currentTransportItem: TransportItem?
    private var nextTransportItem: TransportItem?
    private var activeControllerID: String?

    private let httpPort: NWEndpoint.Port = 49152
    private static let ssdpMulticastHost: NWEndpoint.Host = "239.255.255.250"
    private static let ssdpPort: NWEndpoint.Port = 1900

    init(player: AudioPlayerService) {
        self.player = player
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "dlna.deviceUUID") {
            self.deviceUUID = saved
        } else {
            let new = UUID().uuidString.lowercased()
            defaults.set(new, forKey: "dlna.deviceUUID")
            self.deviceUUID = new
        }
        let device = UIDevice.current.name
        self.friendlyName = "猿音 · \(device)"
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            try startHTTP()
            try startSSDP()
            syncRenderingStateFromEngine()
            installPlayerObservation()
            isRunning = true
            statusText = String(localized: "dlna_status_listening")
            dlnaLog.notice("DLNA renderer started as \(self.friendlyName) (uuid=\(self.deviceUUID))")
        } catch {
            statusText = String(format: String(localized: "dlna_status_error_format"), error.localizedDescription)
            logEvent(.error, "start failed: \(error.localizedDescription)")
            dlnaLog.error("DLNA start failed: \(error.localizedDescription)")
            stop()
        }
    }

    /// 监听 player.isPlaying / currentSong / engine.volume,任一变就给所有
    /// 订阅了对应服务的控制点 POST NOTIFY。`withObservationTracking` 是
    /// 单次的,触发后要 re-arm。Task wrapper 让一直跑着。
    private func installPlayerObservation() {
        playerObservationToken = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tickPlayerObservation()
            }
        }
    }

    private func tickPlayerObservation() async {
        // withObservationTracking 的 onChange 闭包按 SwiftUI Observation 规范
        // 只触发一次 (per registration), 用完即弃; 我们用 continuation 等它,
        // 触发后 resume → 外层循环重新 register, 持续观察。
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = player.isPlaying
                _ = player.currentSong?.id
                _ = player.isAtTrackEnd
                _ = player.audioEngine.volume
                _ = rendererMuted
                _ = lastNonMutedVolume
            } onChange: { [weak self] in
                Task { @MainActor in
                    await self?.handlePlayerStateChange()
                    cont.resume()
                }
            }
        }
    }

    private func handlePlayerStateChange() async {
        syncRenderingStateFromEngine()
        if player.isAtTrackEnd, let next = nextTransportItem {
            nextTransportItem = nil
            logEvent(.control, "AVTransport: auto next → \(next.title)")
            await playTransportItem(next)
        }
        notifyAllSubscribers()
    }

    private func syncRenderingStateFromEngine() {
        let currentVolume = player.audioEngine.volume
        if rendererMuted, currentVolume > 0.001 {
            rendererMuted = false
            lastNonMutedVolume = currentVolume
        } else if !rendererMuted, currentVolume > 0.001 {
            lastNonMutedVolume = currentVolume
        }
    }

    private func notifyAllSubscribers() {
        let now = Date()
        // 顺手清掉过期订阅 (控制点没 UNSUBSCRIBE 就掉线的常见情况)
        subscriptions = subscriptions.filter { $0.value.expiresAt > now }
        for sid in subscriptions.keys {
            sendGenaNotify(sid: sid)
        }
    }

    func stop() {
        // 优雅下线: 先发 byebye 让控制点立刻把我们从设备列表移除,再关 listener
        sendByebyeBatch()
        notifyTask?.cancel(); notifyTask = nil
        playerObservationToken?.cancel(); playerObservationToken = nil
        subscriptions.removeAll()
        connectedDevices.removeAll()
        activeControllerID = nil
        ssdpMulticast?.cancel(); ssdpMulticast = nil
        ssdpListener?.cancel(); ssdpListener = nil
        httpListener?.cancel(); httpListener = nil
        isRunning = false
        statusText = ""
    }

    // MARK: - SSDP

    private func startSSDP() throws {
        // 单播 listener ── 控制点发完 M-SEARCH 后从我们这边收包的 socket
        // 也可能落在这,主要兜底用。多数主流控制点(VLC / Plex)走的是
        // 加入 multicast group 后单播回的模式,这两条路径都要监听。
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: Self.ssdpPort)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.logEvent(.discovery, "SSDP unicast listener ready on UDP \(Self.ssdpPort.rawValue)")
                case .failed(let error):
                    self?.logEvent(.error, "SSDP unicast listener failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleSSDPConnection(conn) }
        }
        listener.start(queue: .main)
        ssdpListener = listener

        // Multicast group ── 监听 239.255.255.250:1900,接受 multicast
        // M-SEARCH (大多数控制点广播找设备),同时拿来发 NOTIFY alive。
        // Network.framework 的 NWConnectionGroup 是 iOS 14+ 标准 multicast
        // 入口,不需要自己撸 setsockopt。
        let multicastParams = NWParameters.udp
        multicastParams.allowLocalEndpointReuse = true
        let multicast = try NWMulticastGroup(
            for: [.hostPort(host: Self.ssdpMulticastHost, port: Self.ssdpPort)]
        )
        let group = NWConnectionGroup(with: multicast, using: multicastParams)
        group.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.logEvent(.discovery, "SSDP multicast group joined \(Self.ssdpMulticastHost):\(Self.ssdpPort.rawValue)")
                case .failed(let error):
                    self?.logEvent(.error, "SSDP multicast failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        group.setReceiveHandler(maximumMessageSize: 65535, rejectOversizedMessages: true) { [weak self] msg, content, _ in
            guard let self, let data = content,
                  let request = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.handleMulticastDatagram(request, message: msg)
            }
        }
        group.start(queue: .main)
        ssdpMulticast = group

        // 启动 NOTIFY alive 广播循环。前 60s 内每 3s 发一次 (新加入网络
        // 的控制点能尽快看到我们),之后改成每 5 分钟,跟 max-age=1800
        // 的标准建议(发送间隔 < max-age/2)对齐。
        notifyTask = Task { [weak self] in
            // 先发一遍 alive 让 multicast group 上已经在听的控制点立刻收到
            await Task.yield()
            self?.sendNotifyBatch(isAlive: true)
            var fastTicks = 0
            while !Task.isCancelled {
                let delay: UInt64 = fastTicks < 20 ? 3 : 300
                try? await Task.sleep(for: .seconds(Int(delay)))
                guard !Task.isCancelled else { break }
                self?.sendNotifyBatch(isAlive: true)
                fastTicks += 1
            }
        }
    }

    private var interestedSSDPTargets: [String] {
        (["ssdp:all"] + usnTypes).map { $0.lowercased() }
    }

    /// Multicast 收到 M-SEARCH 时单播回 200 OK。`NWConnectionGroup` 给的
    /// `message` 里能拿到 reply endpoint,直接走它回。
    private func handleMulticastDatagram(_ request: String, message: NWConnectionGroup.Message) {
        guard request.hasPrefix("M-SEARCH") else { return }
        let lower = request.lowercased()
        guard interestedSSDPTargets.contains(where: { lower.contains($0) }) else { return }
        // 把单播响应直接走 message.reply,不需要单独建 NWConnection。
        let st = headerValue("st", in: request) ?? "?"
        logEvent(.discovery, "M-SEARCH (ST=\(st)) — replied")
        sendSSDPReplies(via: message)
    }

    /// 控制点的 M-SEARCH 一次扫多个 ST,我们按 UPnP/AV 规范每个 NT 都发一遍
    /// 200 OK。3 条 (rootdevice / uuid / device:MediaRenderer:1) 足够命中
    /// 99% 控制点的扫描需求。
    private func sendSSDPReplies(via message: NWConnectionGroup.Message) {
        guard let location = httpLocation() else { return }
        for nt in usnTypes {
            let usn = nt == "uuid:\(deviceUUID)" ? nt : "uuid:\(deviceUUID)::\(nt)"
            let response = """
            HTTP/1.1 200 OK\r
            CACHE-CONTROL: max-age=1800\r
            DATE: \(rfc1123Now())\r
            EXT: \r
            LOCATION: \(location)\r
            SERVER: iOS/UPnP/1.0 Primuse/1.0\r
            ST: \(nt)\r
            USN: \(usn)\r
            \r

            """
            message.reply(content: response.data(using: .utf8))
        }
    }

    /// NOTIFY ssdp:alive ── 周期性 multicast 广播,告诉所有控制点"我还在"。
    /// NT 与 USN 跟 200 OK 同套, 控制点会根据 USN 去重。
    private func sendNotifyBatch(isAlive: Bool) {
        guard let group = ssdpMulticast, let location = httpLocation() else { return }
        let nts = isAlive ? "ssdp:alive" : "ssdp:byebye"
        for nt in usnTypes {
            let usn = nt == "uuid:\(deviceUUID)" ? nt : "uuid:\(deviceUUID)::\(nt)"
            let notify = isAlive
                ? """
                NOTIFY * HTTP/1.1\r
                HOST: 239.255.255.250:1900\r
                CACHE-CONTROL: max-age=1800\r
                LOCATION: \(location)\r
                NT: \(nt)\r
                NTS: \(nts)\r
                SERVER: iOS/UPnP/1.0 Primuse/1.0\r
                USN: \(usn)\r
                \r

                """
                : """
                NOTIFY * HTTP/1.1\r
                HOST: 239.255.255.250:1900\r
                NT: \(nt)\r
                NTS: \(nts)\r
                USN: \(usn)\r
                \r

                """
            group.send(content: notify.data(using: .utf8)) { _ in }
        }
    }

    /// stop() 时同步发一次 byebye。控制点收到后会立刻把我们从设备列表
    /// 移除,而不是等 max-age 过期 (30 分钟)。
    private func sendByebyeBatch() {
        sendNotifyBatch(isAlive: false)
    }

    /// SSDP 一个设备要按 root / uuid / device-type / 各 service-type 分别
    /// 广告自己。控制点根据这些 NT 决定是否感兴趣。
    private var usnTypes: [String] {
        [
            "upnp:rootdevice",
            "uuid:\(deviceUUID)",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:schemas-upnp-org:service:AVTransport:1",
            "urn:schemas-upnp-org:service:RenderingControl:1",
            "urn:schemas-upnp-org:service:ConnectionManager:1",
        ]
    }

    private func handleSSDPConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            Task { @MainActor in
                // 控制点会发 "M-SEARCH * HTTP/1.1 ... ST: urn:schemas-upnp-org:device:MediaRenderer:1"
                // 之类。命中 ST = ssdp:all / MediaRenderer:1 / service type
                // 时,回一个 200 OK SSDP 响应。
                if request.contains("M-SEARCH") {
                    let lower = request.lowercased()
                    if self.interestedSSDPTargets.contains(where: { lower.contains($0) }) {
                        let st = self.headerValue("st", in: request) ?? "?"
                        self.logEvent(.discovery, "M-SEARCH unicast (ST=\(st)) — replied")
                        await self.replySSDP(to: connection)
                        return
                    }
                }
                connection.cancel()
            }
        }
    }

    private func replySSDP(to connection: NWConnection) async {
        guard let location = httpLocation() else { connection.cancel(); return }
        let response = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age=1800\r
        DATE: \(rfc1123Now())\r
        EXT: \r
        LOCATION: \(location)\r
        SERVER: iOS/UPnP/1.0 Primuse/1.0\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        USN: uuid:\(deviceUUID)::urn:schemas-upnp-org:device:MediaRenderer:1\r
        \r
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP

    private func startHTTP() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: httpPort)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.logEvent(.event, "HTTP control server ready on TCP \(self?.httpPort.rawValue ?? 0)")
                case .failed(let error):
                    self?.logEvent(.error, "HTTP control server failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleHTTPConnection(conn) }
        }
        listener.start(queue: .main)
        httpListener = listener
    }

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error {
                dlnaLog.debug("HTTP receive err: \(error.localizedDescription)")
                connection.cancel(); return
            }
            guard let data else {
                if isComplete { connection.cancel() }
                return
            }
            var nextBuffer = buffer
            nextBuffer.append(data)
            guard nextBuffer.count <= 1_000_000 else {
                Task { @MainActor in await self.sendStatus(413, on: connection) }
                return
            }
            if let text = self.completedHTTPRequestText(from: nextBuffer) {
                Task { @MainActor in await self.routeHTTP(text, connection: connection) }
            } else if isComplete {
                connection.cancel()
            } else {
                Task { @MainActor in self.receiveHTTPRequest(on: connection, buffer: nextBuffer) }
            }
        }
    }

    nonisolated private func completedHTTPRequestText(from data: Data) -> String? {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: marker)?.upperBound else { return nil }
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                let value = line.split(separator: ":", maxSplits: 1).last ?? ""
                return Int(value.trimmingCharacters(in: .whitespaces))
            } ?? 0
        let totalLength = headerEnd + contentLength
        guard data.count >= totalLength else { return nil }
        return String(data: data.prefix(totalLength), encoding: .utf8)
    }

    private func routeHTTP(_ raw: String, connection: NWConnection) async {
        let lines = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { connection.cancel(); return }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1])
        let controllerID = rememberController(from: raw, connection: connection)
        logEvent(.control, "HTTP \(method) \(path) from \(remoteDescription(connection))")

        switch (method, path) {
        case ("GET", "/device.xml"):
            await sendXML(deviceDescriptionXML(), on: connection)
        case ("GET", "/AVTransport.xml"):
            await sendXML(avTransportSCPD, on: connection)
        case ("GET", "/RenderingControl.xml"):
            await sendXML(renderingControlSCPD, on: connection)
        case ("GET", "/ConnectionManager.xml"):
            await sendXML(connectionManagerSCPD, on: connection)
        case ("POST", "/control/AVTransport"):
            await handleAVTransportAction(raw: raw, connection: connection, controllerID: controllerID)
        case ("POST", "/control/RenderingControl"):
            await handleRenderingControlAction(raw: raw, connection: connection)
        case ("POST", "/control/ConnectionManager"):
            await handleConnectionManagerAction(raw: raw, connection: connection)
        case ("SUBSCRIBE", "/event/AVTransport"):
            await handleSubscribe(service: "AVTransport", raw: raw, connection: connection)
        case ("SUBSCRIBE", "/event/RenderingControl"):
            await handleSubscribe(service: "RenderingControl", raw: raw, connection: connection)
        case ("SUBSCRIBE", "/event/ConnectionManager"):
            await handleSubscribe(service: "ConnectionManager", raw: raw, connection: connection)
        case ("UNSUBSCRIBE", "/event/AVTransport"),
             ("UNSUBSCRIBE", "/event/RenderingControl"),
             ("UNSUBSCRIBE", "/event/ConnectionManager"):
            await handleUnsubscribe(raw: raw, connection: connection)
        default:
            await sendStatus(404, on: connection)
        }
    }

    // MARK: - RenderingControl (音量同步)

    private var renderingVolumePercent: Int {
        let volume = rendererMuted ? lastNonMutedVolume : player.audioEngine.volume
        return max(0, min(100, Int((volume * 100).rounded())))
    }

    private func setRenderingVolumePercent(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        let normalized = Float(clamped) / 100
        lastNonMutedVolume = normalized
        if !rendererMuted {
            player.audioEngine.volume = normalized
        }
        notifyAllSubscribers()
    }

    private func setRenderingMuted(_ muted: Bool) {
        if muted {
            let currentVolume = player.audioEngine.volume
            if currentVolume > 0.001 {
                lastNonMutedVolume = currentVolume
            }
            rendererMuted = true
            player.audioEngine.volume = 0
        } else {
            rendererMuted = false
            player.audioEngine.volume = lastNonMutedVolume
        }
        notifyAllSubscribers()
    }

    private func handleRenderingControlAction(raw: String, connection: NWConnection) async {
        let soapActionLine = raw.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("soapaction:") }
            .map(String.init) ?? ""
        let action = soapActionLine.split(separator: "#").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r\n ")) ?? ""
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        logEvent(.control, "RenderingControl: \(action)")

        switch action {
        case "GetVolume":
            await sendRCSOAP(
                action: "GetVolume",
                body: "<CurrentVolume>\(renderingVolumePercent)</CurrentVolume>",
                on: connection
            )
        case "SetVolume":
            // body 里 <DesiredVolume>NN</DesiredVolume>; 范围 0-100。
            if let str = extract(tag: "DesiredVolume", from: body), let v = Int(str) {
                setRenderingVolumePercent(v)
            }
            await sendRCSOAP(action: "SetVolume", body: "", on: connection)
        case "GetMute":
            await sendRCSOAP(
                action: "GetMute",
                body: "<CurrentMute>\(rendererMuted ? 1 : 0)</CurrentMute>",
                on: connection
            )
        case "SetMute":
            if let str = extract(tag: "DesiredMute", from: body) {
                let shouldMute = (str == "1" || str.lowercased() == "true")
                setRenderingMuted(shouldMute)
            }
            await sendRCSOAP(action: "SetMute", body: "", on: connection)
        default:
            await sendRCSOAP(action: action, body: "", on: connection)
        }
    }

    private func sendRCSOAP(action: String, body: String, on connection: NWConnection) async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
        await sendXML(xml, on: connection)
    }

    // MARK: - ConnectionManager

    private var sinkProtocolInfo: String {
        [
            "http-get:*:audio/mpeg:*",
            "http-get:*:audio/aac:*",
            "http-get:*:audio/mp4:*",
            "http-get:*:audio/flac:*",
            "http-get:*:audio/x-flac:*",
            "http-get:*:audio/wav:*",
            "http-get:*:audio/x-wav:*",
            "http-get:*:audio/ogg:*",
            "http-get:*:audio/opus:*",
            "http-get:*:application/ogg:*"
        ].joined(separator: ",")
    }

    private func handleConnectionManagerAction(raw: String, connection: NWConnection) async {
        let soapActionLine = raw.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("soapaction:") }
            .map(String.init) ?? ""
        let action = soapActionLine.split(separator: "#").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r\n ")) ?? ""
        logEvent(.control, "ConnectionManager: \(action)")

        switch action {
        case "GetProtocolInfo":
            let body = """
            <Source></Source>
            <Sink>\(sinkProtocolInfo)</Sink>
            """
            await sendCMSOAP(action: "GetProtocolInfo", body: body, on: connection)
        case "GetCurrentConnectionIDs":
            await sendCMSOAP(action: "GetCurrentConnectionIDs", body: "<ConnectionIDs>0</ConnectionIDs>", on: connection)
        case "GetCurrentConnectionInfo":
            let body = """
            <RcsID>0</RcsID>
            <AVTransportID>0</AVTransportID>
            <ProtocolInfo></ProtocolInfo>
            <PeerConnectionManager></PeerConnectionManager>
            <PeerConnectionID>-1</PeerConnectionID>
            <Direction>Input</Direction>
            <Status>OK</Status>
            """
            await sendCMSOAP(action: "GetCurrentConnectionInfo", body: body, on: connection)
        case "PrepareForConnection":
            let body = """
            <ConnectionID>0</ConnectionID>
            <AVTransportID>0</AVTransportID>
            <RcsID>0</RcsID>
            """
            await sendCMSOAP(action: "PrepareForConnection", body: body, on: connection)
        case "ConnectionComplete":
            await sendCMSOAP(action: "ConnectionComplete", body: "", on: connection)
        default:
            await sendCMSOAP(action: action, body: "", on: connection)
        }
    }

    private func sendCMSOAP(action: String, body: String, on connection: NWConnection) async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
        await sendXML(xml, on: connection)
    }

    // MARK: - GENA (事件订阅)

    private func handleSubscribe(service: String, raw: String, connection: NWConnection) async {
        let lines = raw.split(separator: "\r\n").map(String.init)
        var headers: [String: String] = [:]
        for (key, value) in lines.compactMap({ line -> (String, String)? in
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            return (kv[0].lowercased().trimmingCharacters(in: .whitespaces),
                    kv[1].trimmingCharacters(in: .whitespaces))
        }) {
            headers[key] = value
        }
        if let existingSID = headers["sid"], var sub = subscriptions[existingSID] {
            let timeoutSeconds = parseTimeout(headers["timeout"]) ?? 1800
            sub.expiresAt = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            subscriptions[existingSID] = sub
            logEvent(.event, "RENEW \(service) (sid=\(existingSID.suffix(8)))")
            await sendSubscribeResponse(sid: existingSID, timeoutSeconds: timeoutSeconds, on: connection)
            return
        }

        // CALLBACK 形如 "<http://192.168.1.20:7676/abcd>" 可能多个 URL,取第一个
        guard let callbackHeader = headers["callback"],
              let urlStr = callbackHeader.split(separator: "<").last?.split(separator: ">").first,
              let callbackURL = URL(string: String(urlStr)) else {
            await sendStatus(400, on: connection); return
        }
        let timeoutSeconds = parseTimeout(headers["timeout"]) ?? 1800
        let sid = "uuid:\(UUID().uuidString.lowercased())"
        let sub = Subscription(
            sid: sid,
            service: service,
            callbackURL: callbackURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        )
        subscriptions[sid] = sub
        logEvent(.event, "SUBSCRIBE \(service) → \(callbackURL.host ?? "?") (sid=\(sid.suffix(8)))")
        await sendSubscribeResponse(sid: sid, timeoutSeconds: timeoutSeconds, on: connection)
        // 按规范, SUBSCRIBE 返回 200 后立刻发一次"initial event" 把当前状态推过去
        sendGenaNotify(sid: sid)
    }

    private func sendSubscribeResponse(sid: String, timeoutSeconds: Int, on connection: NWConnection) async {
        let response = """
        HTTP/1.1 200 OK\r
        DATE: \(rfc1123Now())\r
        SERVER: iOS/UPnP/1.0 Primuse/1.0\r
        SID: \(sid)\r
        TIMEOUT: Second-\(timeoutSeconds)\r
        Content-Length: 0\r
        \r

        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleUnsubscribe(raw: String, connection: NWConnection) async {
        if let sidLine = raw.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("sid:") }) {
            let sid = sidLine.split(separator: ":", maxSplits: 1)
                .last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            subscriptions.removeValue(forKey: sid)
            logEvent(.event, "UNSUBSCRIBE (sid=\(sid.suffix(8)))")
        }
        await sendStatus(200, on: connection)
    }

    /// 给指定 SID 发一次 NOTIFY。body 是 service 对应的 LastChange xml,
    /// 包了一层 <e:propertyset>/<e:property>。
    private func sendGenaNotify(sid: String) {
        guard let sub = subscriptions[sid] else { return }
        guard let body = makeEventBody(for: sub.service) else { return }
        var newSub = sub
        newSub.seq += 1
        subscriptions[sid] = newSub

        var request = URLRequest(url: sub.callbackURL)
        request.httpMethod = "NOTIFY"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue(String(newSub.seq), forHTTPHeaderField: "SEQ")
        request.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: request) { _, _, _ in /* fire and forget */ }.resume()
    }

    private func makeEventBody(for service: String) -> String? {
        switch service {
        case "AVTransport":
            let state = player.isPlaying ? "PLAYING" : (player.currentSong != nil ? "PAUSED_PLAYBACK" : "STOPPED")
            let current = currentTransportItem
            let next = nextTransportItem
            let lastChange = """
            <Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
              <InstanceID val="0">
                <TransportState val="\(state)"/>
                <TransportStatus val="OK"/>
                <AVTransportURI val="\(xmlEscape(current?.uri ?? ""))"/>
                <AVTransportURIMetaData val="\(xmlEscape(didl(for: current)))"/>
                <NextAVTransportURI val="\(xmlEscape(next?.uri ?? ""))"/>
                <NextAVTransportURIMetaData val="\(xmlEscape(didl(for: next)))"/>
                <CurrentTrackURI val="\(xmlEscape(current?.uri ?? player.currentSong?.filePath ?? ""))"/>
                <CurrentTrack val="1"/>
                <CurrentTrackDuration val="\(formatTime(player.duration))"/>
                <CurrentTrackMetaData val="\(xmlEscape(didl(for: current)))"/>
                <CurrentTransportActions val="\(currentTransportActions().joined(separator: ","))"/>
              </InstanceID>
            </Event>
            """
            return wrapPropertyset(varName: "LastChange", value: lastChange)
        case "RenderingControl":
            let lastChange = """
            <Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/">
              <InstanceID val="0">
                <Volume channel="Master" val="\(renderingVolumePercent)"/>
                <Mute channel="Master" val="\(rendererMuted ? 1 : 0)"/>
              </InstanceID>
            </Event>
            """
            return wrapPropertyset(varName: "LastChange", value: lastChange)
        case "ConnectionManager":
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
              <e:property><SourceProtocolInfo></SourceProtocolInfo></e:property>
              <e:property><SinkProtocolInfo>\(xmlEscape(sinkProtocolInfo))</SinkProtocolInfo></e:property>
              <e:property><CurrentConnectionIDs>0</CurrentConnectionIDs></e:property>
            </e:propertyset>
            """
            return body
        default:
            return nil
        }
    }

    private func wrapPropertyset(varName: String, value: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property>
            <\(varName)>\(xmlEscape(value))</\(varName)>
          </e:property>
        </e:propertyset>
        """
    }

    private func didlForCurrent(title: String) -> String {
        // 极简 DIDL-Lite,只放 title,够大多数控制点显示"现在播放什么"。
        guard !title.isEmpty else { return "" }
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="0" parentID="0" restricted="1">
        <dc:title>\(xmlEscape(title))</dc:title>
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>
        </item>
        </DIDL-Lite>
        """
    }

    private func didl(for item: TransportItem?) -> String {
        guard let item else { return "" }
        if item.metadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return item.metadata
        }
        return didlForCurrent(title: item.title)
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// "Second-1800" / "Second-infinite" / 缺失 → 默认 1800
    private func parseTimeout(_ header: String?) -> Int? {
        guard let header else { return nil }
        let trimmed = header.lowercased().replacingOccurrences(of: "second-", with: "")
        if trimmed == "infinite" { return 1800 } // 我们最长跟自己保活的节奏对齐
        return Int(trimmed)
    }

    private func handleAVTransportAction(raw: String, connection: NWConnection, controllerID: String) async {
        // SOAPAction header 形如 `"urn:schemas-upnp-org:service:AVTransport:1#Play"`
        let soapActionLine = headerValue("soapaction", in: raw) ?? ""
        let action = soapActionLine.split(separator: "#").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r\n ")) ?? ""

        // SOAP body 在 \r\n\r\n 之后
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")

        logEvent(.control, "AVTransport: \(action)")
        switch action {
        case "SetAVTransportURI":
            // body 里 <CurrentURI>...</CurrentURI>; <CurrentURIMetaData>didl xml</...>
            guard let item = transportItem(uriTag: "CurrentURI", metadataTag: "CurrentURIMetaData", from: body) else {
                logEvent(.error, "AVTransport SetAVTransportURI missing or invalid URI")
                await sendSOAPError(code: 714, description: "Illegal MIME-Type", on: connection)
                return
            }
            logEvent(.control, "Set current URI → \(item.title) (\(item.url.host ?? item.url.scheme ?? "?"))")
            markController(controllerID, isCasting: true)
            await playTransportItem(item)
            await sendSOAP(action: "SetAVTransportURI", body: "", on: connection)
        case "SetNextAVTransportURI":
            guard let item = transportItem(uriTag: "NextURI", metadataTag: "NextURIMetaData", from: body) else {
                logEvent(.error, "AVTransport SetNextAVTransportURI missing or invalid URI")
                await sendSOAPError(code: 714, description: "Illegal MIME-Type", on: connection)
                return
            }
            nextTransportItem = item
            logEvent(.control, "Set next URI → \(item.title) (\(item.url.host ?? item.url.scheme ?? "?"))")
            notifyAllSubscribers()
            await sendSOAP(action: "SetNextAVTransportURI", body: "", on: connection)
        case "Play":
            markController(controllerID, isCasting: true)
            if !player.isPlaying, let current = currentTransportItem, player.currentSong == nil {
                await playTransportItem(current)
            } else if !player.isPlaying {
                player.resume()
            }
            await sendSOAP(action: "Play", body: "", on: connection)
        case "Pause":
            if player.isPlaying { player.togglePlayPause() }
            await sendSOAP(action: "Pause", body: "", on: connection)
        case "Stop":
            player.stop()
            markController(controllerID, isCasting: false)
            statusText = String(localized: "dlna_status_listening")
            await sendSOAP(action: "Stop", body: "", on: connection)
        case "Next":
            guard let next = nextTransportItem else {
                await sendSOAPError(code: 711, description: "Transition not available", on: connection)
                return
            }
            nextTransportItem = nil
            markController(controllerID, isCasting: true)
            await playTransportItem(next)
            await sendSOAP(action: "Next", body: "", on: connection)
        case "Previous":
            await sendSOAPError(code: 711, description: "Transition not available", on: connection)
        case "GetTransportInfo":
            let state: String
            if player.isPlaying {
                state = "PLAYING"
            } else if player.currentSong != nil {
                state = "PAUSED_PLAYBACK"
            } else {
                state = "STOPPED"
            }
            let body = """
            <CurrentTransportState>\(state)</CurrentTransportState>
            <CurrentTransportStatus>OK</CurrentTransportStatus>
            <CurrentSpeed>1</CurrentSpeed>
            """
            await sendSOAP(action: "GetTransportInfo", body: body, on: connection)
        case "GetTransportSettings":
            let body = """
            <PlayMode>NORMAL</PlayMode>
            <RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>
            """
            await sendSOAP(action: "GetTransportSettings", body: body, on: connection)
        case "GetDeviceCapabilities":
            let body = """
            <PlayMedia>NETWORK</PlayMedia>
            <RecMedia>NOT_IMPLEMENTED</RecMedia>
            <RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>
            """
            await sendSOAP(action: "GetDeviceCapabilities", body: body, on: connection)
        case "GetMediaInfo":
            let current = currentTransportItem
            let next = nextTransportItem
            let body = """
            <NrTracks>\(current == nil ? 0 : 1)</NrTracks>
            <MediaDuration>\(formatTime(player.duration))</MediaDuration>
            <CurrentURI>\(xmlEscape(current?.uri ?? player.currentSong?.filePath ?? ""))</CurrentURI>
            <CurrentURIMetaData>\(xmlEscape(didl(for: current)))</CurrentURIMetaData>
            <NextURI>\(xmlEscape(next?.uri ?? ""))</NextURI>
            <NextURIMetaData>\(xmlEscape(didl(for: next)))</NextURIMetaData>
            <PlayMedium>NETWORK</PlayMedium>
            <RecordMedium>NOT_IMPLEMENTED</RecordMedium>
            <WriteStatus>NOT_IMPLEMENTED</WriteStatus>
            """
            await sendSOAP(action: "GetMediaInfo", body: body, on: connection)
        case "GetPositionInfo":
            let cur = formatTime(player.currentTime)
            let dur = formatTime(player.duration)
            let current = currentTransportItem
            let body = """
            <Track>\(current == nil ? 0 : 1)</Track>
            <TrackDuration>\(dur)</TrackDuration>
            <TrackMetaData>\(xmlEscape(didl(for: current)))</TrackMetaData>
            <TrackURI>\(xmlEscape(current?.uri ?? player.currentSong?.filePath ?? ""))</TrackURI>
            <RelTime>\(cur)</RelTime>
            <AbsTime>\(cur)</AbsTime>
            <RelCount>2147483647</RelCount>
            <AbsCount>2147483647</AbsCount>
            """
            await sendSOAP(action: "GetPositionInfo", body: body, on: connection)
        case "GetCurrentTransportActions":
            await sendSOAP(
                action: "GetCurrentTransportActions",
                body: "<Actions>\(currentTransportActions().joined(separator: ","))</Actions>",
                on: connection
            )
        case "Seek":
            if let target = extract(tag: "Target", from: body),
               let seconds = parseTime(target) {
                player.seek(to: seconds, startPlaying: player.isPlaying)
            }
            await sendSOAP(action: "Seek", body: "", on: connection)
        default:
            logEvent(.error, "AVTransport unsupported action: \(action)")
            await sendSOAPError(code: 401, description: "Invalid Action", on: connection)
        }
    }

    private func currentTransportActions() -> [String] {
        var actions: [String] = []
        if currentTransportItem != nil || player.currentSong != nil {
            actions.append("Play")
            actions.append("Stop")
            actions.append("Seek")
            if player.isPlaying {
                actions.append("Pause")
            }
        }
        if nextTransportItem != nil {
            actions.append("Next")
        }
        return actions.isEmpty ? ["Play"] : actions
    }

    private func transportItem(uriTag: String, metadataTag: String, from body: String) -> TransportItem? {
        guard let rawURI = extract(tag: uriTag, from: body)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawURI.isEmpty == false,
              let url = URL(string: rawURI) else {
            return nil
        }

        let metadata = extract(tag: metadataTag, from: body) ?? ""
        let title = extract(tag: "dc:title", from: metadata)
            ?? extract(tag: "title", from: metadata)
            ?? url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? String(localized: "dlna_stream_title_fallback")
        let artist = extract(tag: "upnp:artist", from: metadata)
            ?? extract(tag: "dc:creator", from: metadata)
            ?? extract(tag: "creator", from: metadata)
        return TransportItem(
            uri: rawURI,
            metadata: metadata,
            title: title.isEmpty ? String(localized: "dlna_stream_title_fallback") : title,
            artist: artist,
            url: url
        )
    }

    private func playTransportItem(_ item: TransportItem) async {
        currentTransportItem = item
        await playRemote(url: item.url, title: item.title, artist: item.artist)
        statusText = String(format: String(localized: "dlna_status_playing_format"), item.title)
        notifyAllSubscribers()
    }

    /// 创建一个临时 Song 喂给 player.play(song:from:)。sourceID 用 "dlna"
    /// 标识来源,filePath 存 URL ── 走的是 AudioPlayerService 的 "from URL"
    /// 分支,跟我们的 MusicSource 系统完全独立,不会污染库。
    private func playRemote(url: URL, title: String, artist: String?) async {
        let song = Song(
            id: "dlna:\(UUID().uuidString)",
            title: title,
            artistName: artist,
            duration: 0,
            fileFormat: AudioFormat.from(fileExtension: url.pathExtension) ?? .mp3,
            filePath: url.absoluteString,
            sourceID: "dlna"
        )
        await player.play(song: song, from: url)
    }

    // MARK: - XML helpers

    private func deviceDescriptionXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>\(xmlEscape(friendlyName))</friendlyName>
            <manufacturer>Welape</manufacturer>
            <modelName>Primuse</modelName>
            <modelNumber>1.0</modelNumber>
            <UDN>uuid:\(deviceUUID)</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
                <SCPDURL>/AVTransport.xml</SCPDURL>
                <controlURL>/control/AVTransport</controlURL>
                <eventSubURL>/event/AVTransport</eventSubURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
                <SCPDURL>/RenderingControl.xml</SCPDURL>
                <controlURL>/control/RenderingControl</controlURL>
                <eventSubURL>/event/RenderingControl</eventSubURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                <SCPDURL>/ConnectionManager.xml</SCPDURL>
                <controlURL>/control/ConnectionManager</controlURL>
                <eventSubURL>/event/ConnectionManager</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }

    private var avTransportSCPD: String {
        // 声明当前实际能响应的 AVTransport action。保留完整 argumentList,
        // 避免严格控制点因 SCPD 太空而判定设备不可控。
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList>
            <action>
              <name>SetAVTransportURI</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
                <argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>SetNextAVTransportURI</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>NextURI</name><direction>in</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
                <argument><name>NextURIMetaData</name><direction>in</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Play</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Pause</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Stop</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Next</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Previous</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>Seek</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
                <argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetMediaInfo</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>NrTracks</name><direction>out</direction><relatedStateVariable>NumberOfTracks</relatedStateVariable></argument>
                <argument><name>MediaDuration</name><direction>out</direction><relatedStateVariable>CurrentMediaDuration</relatedStateVariable></argument>
                <argument><name>CurrentURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
                <argument><name>CurrentURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
                <argument><name>NextURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
                <argument><name>NextURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
                <argument><name>PlayMedium</name><direction>out</direction><relatedStateVariable>PlaybackStorageMedium</relatedStateVariable></argument>
                <argument><name>RecordMedium</name><direction>out</direction><relatedStateVariable>RecordStorageMedium</relatedStateVariable></argument>
                <argument><name>WriteStatus</name><direction>out</direction><relatedStateVariable>RecordMediumWriteStatus</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetTransportSettings</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>PlayMode</name><direction>out</direction><relatedStateVariable>CurrentPlayMode</relatedStateVariable></argument>
                <argument><name>RecQualityMode</name><direction>out</direction><relatedStateVariable>CurrentRecordQualityMode</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetDeviceCapabilities</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>PlayMedia</name><direction>out</direction><relatedStateVariable>PossiblePlaybackStorageMedia</relatedStateVariable></argument>
                <argument><name>RecMedia</name><direction>out</direction><relatedStateVariable>PossibleRecordStorageMedia</relatedStateVariable></argument>
                <argument><name>RecQualityModes</name><direction>out</direction><relatedStateVariable>PossibleRecordQualityModes</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetTransportInfo</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
                <argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
                <argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetPositionInfo</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
                <argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
                <argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
                <argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
                <argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
                <argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
                <argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
                <argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetCurrentTransportActions</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Actions</name><direction>out</direction><relatedStateVariable>CurrentTransportActions</relatedStateVariable></argument>
              </argumentList>
            </action>
          </actionList>
          <serviceStateTable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType><allowedValueList><allowedValue>1</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType><allowedValueList><allowedValue>REL_TIME</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="yes"><name>TransportState</name><dataType>string</dataType><allowedValueList><allowedValue>STOPPED</allowedValue><allowedValue>PLAYING</allowedValue><allowedValue>PAUSED_PLAYBACK</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="yes"><name>TransportStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentTransportActions</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentPlayMode</name><dataType>string</dataType><allowedValueList><allowedValue>NORMAL</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentRecordQualityMode</name><dataType>string</dataType><allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>PossiblePlaybackStorageMedia</name><dataType>string</dataType><allowedValueList><allowedValue>NETWORK</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>PossibleRecordStorageMedia</name><dataType>string</dataType><allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>PossibleRecordQualityModes</name><dataType>string</dataType><allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>PlaybackStorageMedium</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>RecordStorageMedium</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>RecordMediumWriteStatus</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
            <stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
          </serviceStateTable>
        </scpd>
        """
    }

    private var renderingControlSCPD: String {
        // Volume / Mute 双向同步。Channel=Master 只支持 single-channel master volume,
        // 不暴露 LF/RF/Surround 等 multi-channel state vars,简化但够主流控制点用。
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList>
            <action>
              <name>GetVolume</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
                <argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>SetVolume</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
                <argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetMute</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
                <argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>SetMute</name>
              <argumentList>
                <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
                <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
                <argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
              </argumentList>
            </action>
          </actionList>
          <serviceStateTable>
            <stateVariable sendEvents="yes"><name>Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
            <stateVariable sendEvents="yes"><name>Mute</name><dataType>boolean</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_Channel</name><dataType>string</dataType><allowedValueList><allowedValue>Master</allowedValue></allowedValueList></stateVariable>
          </serviceStateTable>
        </scpd>
        """
    }

    private var connectionManagerSCPD: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList>
            <action>
              <name>GetProtocolInfo</name>
              <argumentList>
                <argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
                <argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetCurrentConnectionIDs</name>
              <argumentList>
                <argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>GetCurrentConnectionInfo</name>
              <argumentList>
                <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
                <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
                <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
                <argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
                <argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
                <argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
                <argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
                <argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>PrepareForConnection</name>
              <argumentList>
                <argument><name>RemoteProtocolInfo</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
                <argument><name>PeerConnectionManager</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
                <argument><name>PeerConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
                <argument><name>Direction</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
                <argument><name>ConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
                <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
                <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
              </argumentList>
            </action>
            <action>
              <name>ConnectionComplete</name>
              <argumentList>
                <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
              </argumentList>
            </action>
          </actionList>
          <serviceStateTable>
            <stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="yes"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType><allowedValueList><allowedValue>Input</allowedValue></allowedValueList></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
            <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
          </serviceStateTable>
        </scpd>
        """
    }

    // MARK: - Networking helpers

    private func headerValue(_ name: String, in raw: String) -> String? {
        let wanted = name.lowercased()
        return raw.split(separator: "\r\n")
            .first { line in
                line.split(separator: ":", maxSplits: 1).first?.lowercased() == wanted
            }
            .flatMap { line in
                line.split(separator: ":", maxSplits: 1).last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    @discardableResult
    private func rememberController(from raw: String, connection: NWConnection) -> String {
        let address = remoteHost(connection)
        let userAgent = headerValue("user-agent", in: raw)
            ?? headerValue("server", in: raw)
        let name = controllerName(from: userAgent, address: address)
        let detail = controllerDetail(from: userAgent, name: name)
        let now = Date()

        if let index = connectedDevices.firstIndex(where: { $0.id == address }) {
            connectedDevices[index].name = name
            connectedDevices[index].address = address
            connectedDevices[index].clientDescription = detail
            connectedDevices[index].lastSeen = now
        } else {
            connectedDevices.insert(
                ConnectedDevice(
                    id: address,
                    name: name,
                    address: address,
                    clientDescription: detail,
                    lastSeen: now,
                    isCasting: false
                ),
                at: 0
            )
        }
        sortConnectedDevices()
        return address
    }

    private func markController(_ id: String, isCasting: Bool) {
        if isCasting {
            if let previous = activeControllerID,
               previous != id,
               let previousIndex = connectedDevices.firstIndex(where: { $0.id == previous }) {
                connectedDevices[previousIndex].isCasting = false
            }
            activeControllerID = id
        } else if activeControllerID == id {
            activeControllerID = nil
        }

        guard let index = connectedDevices.firstIndex(where: { $0.id == id }) else { return }
        connectedDevices[index].isCasting = isCasting
        connectedDevices[index].lastSeen = Date()
        sortConnectedDevices()
    }

    private func sortConnectedDevices() {
        connectedDevices.sort { lhs, rhs in
            if lhs.isCasting != rhs.isCasting {
                return lhs.isCasting && !rhs.isCasting
            }
            return lhs.lastSeen > rhs.lastSeen
        }
        if connectedDevices.count > Self.maxConnectedDevices {
            connectedDevices.removeLast(connectedDevices.count - Self.maxConnectedDevices)
        }
    }

    private func controllerName(from userAgent: String?, address: String) -> String {
        guard let userAgent else { return address }
        let cleaned = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return address }

        let lower = cleaned.lowercased()
        let knownClients: [(needle: String, name: String)] = [
            ("vlc", "VLC"),
            ("plex", "Plex"),
            ("hi-fi cast", "Hi-Fi Cast"),
            ("hificast", "Hi-Fi Cast"),
            ("bubbleupnp", "BubbleUPnP"),
            ("audio station", "Audio Station"),
            ("audiostation", "Audio Station"),
            ("synology", "Synology Audio Station"),
            ("foobar", "foobar2000"),
            ("kodi", "Kodi"),
            ("windows", "Windows DLNA")
        ]
        if let matched = knownClients.first(where: { lower.contains($0.needle) }) {
            return matched.name
        }

        let token = cleaned
            .split { char in char == " " || char == "(" || char == ";" }
            .first
            .map(String.init)?
            .split(separator: "/")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .punctuationCharacters)
        if let token, token.count > 1, token.lowercased() != "upnp" {
            return token
        }
        return address
    }

    private func controllerDetail(from userAgent: String?, name: String) -> String? {
        guard let userAgent else { return nil }
        let cleaned = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != name else { return nil }
        if cleaned.count > 64 {
            return String(cleaned.prefix(61)) + "..."
        }
        return cleaned
    }

    private func remoteHost(_ connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return String(describing: host)
        default:
            return String(describing: connection.endpoint)
        }
    }

    private func remoteDescription(_ connection: NWConnection) -> String {
        String(describing: connection.endpoint)
    }

    private func sendXML(_ xml: String, on connection: NWConnection) async {
        let data = xml.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/xml; charset=utf-8\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r

        """
        let bytes = (headers.data(using: .utf8) ?? Data()) + data
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendSOAPError(code: Int, description: String, on connection: NWConnection) async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <s:Fault>
        <faultcode>s:Client</faultcode>
        <faultstring>UPnPError</faultstring>
        <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
        <errorCode>\(code)</errorCode>
        <errorDescription>\(xmlEscape(description))</errorDescription>
        </UPnPError>
        </detail>
        </s:Fault>
        </s:Body>
        </s:Envelope>
        """
        let data = xml.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 500 Internal Server Error\r
        Content-Type: text/xml; charset=utf-8\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r

        """
        let bytes = (headers.data(using: .utf8) ?? Data()) + data
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStatus(_ code: Int, on connection: NWConnection) async {
        let response = "HTTP/1.1 \(code) \(reasonPhrase(for: code))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    private func sendSOAP(action: String, body: String, on connection: NWConnection) async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
        await sendXML(xml, on: connection)
    }

    private func httpLocation() -> String? {
        guard let ip = primaryIPv4() else { return nil }
        return "http://\(ip):\(httpPort.rawValue)/device.xml"
    }

    /// 取出"en0" / "pdp_ip0"等接口的 IPv4 地址,做 SSDP LOCATION 用。
    private func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [String: String] = [:]
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let n = node {
            let flags = Int32(n.pointee.ifa_flags)
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               let addr = n.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: n.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let res = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                       &host, socklen_t(host.count),
                                       nil, 0, NI_NUMERICHOST)
                if res == 0 {
                    candidates[name] = host.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return "" }
                        return String(cString: base)
                    }
                }
            }
            node = n.pointee.ifa_next
        }
        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.first
    }

    private func rfc1123Now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "00:00:00" }
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func parseTime(_ raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// 简单 XML extract,够用 ── DIDL-Lite metadata 是 escape 过的 XML
    /// 嵌在 CurrentURIMetaData 里, 我们先 unescape, 再正则提单 tag。
    private func extract(tag: String, from xml: String?) -> String? {
        guard let xml else { return nil }
        let decoded = xml
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let open = "<\(tag)"
        guard let openRange = decoded.range(of: open) else { return nil }
        guard let closeRange = decoded.range(of: "</\(tag)>", range: openRange.upperBound..<decoded.endIndex) else { return nil }
        let afterOpen = decoded[openRange.upperBound..<closeRange.lowerBound]
        // 跳过开标签里可能的属性,落到 >
        guard let bracket = afterOpen.firstIndex(of: ">") else { return nil }
        return String(afterOpen[afterOpen.index(after: bracket)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
