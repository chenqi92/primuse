import Foundation
import Network
import OSLog
#if os(iOS)
import UIKit
#endif
import PrimuseKit

/// LAN 内被发现的 UPnP/AV MediaRenderer 设备 ── 投屏目标。
/// 文件内 struct (不单独建 .swift) 避免改 pbxproj。
struct RemoteRenderer: Identifiable, Hashable, Sendable {
    let udn: String
    var friendlyName: String
    var host: String
    let location: URL
    var avTransportControlURL: URL?
    var renderingControlControlURL: URL?
    var connectionManagerControlURL: URL?
    var avTransportEventURL: URL?
    var renderingControlEventURL: URL?
    var sinkProtocolInfo: [String] = []
    var manufacturer: String?
    var modelName: String?
    var lastSeen: Date
    var id: String { udn }
}

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

    /// LAN 内被发现的可投屏目标 (UPnP MediaRenderer 设备), 按 UDN 去重。
    /// Controller UI 直接读这个让用户选投屏目标。
    private(set) var discoveredRenderers: [String: RemoteRenderer] = [:]

    /// 主动 M-SEARCH 周期任务 ── 跟 NOTIFY alive 并存, 这边主动扫别人, 那边
    /// 别人主动扫我们。停 DLNA service 时一起 cancel。
    private var discoveryTask: Task<Void, Never>?

    /// 拉 device.xml 的 URLSession ── 复用 SmartSSLDelegate 跟项目其他 NAS
    /// 请求一致, 但 DLNA renderer 一般是 LAN HTTP 不需要 SSL trust override。
    private let discoverySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func logEvent(_ kind: DebugEvent.Kind, _ detail: String) {
        let tag: String
        switch kind {
        case .discovery:
            dlnaLog.info("discovery: \(detail, privacy: .public)")
            tag = "🔍 discovery"
        case .control:
            dlnaLog.info("control: \(detail, privacy: .public)")
            tag = "🎛 control"
        case .event:
            dlnaLog.info("event: \(detail, privacy: .public)")
            tag = "📣 event"
        case .error:
            dlnaLog.error("error: \(detail, privacy: .public)")
            tag = "❌ error"
        }
        // 同时打到 FileLogger, 让用户拉日志做诊断时能看到 DLNA 全程
        // (os.Logger 进 Console.app, 跨设备不便)。
        plog("[DLNA] \(tag) \(detail)")
        recentEvents.insert(
            DebugEvent(timestamp: Date(), kind: kind, detail: detail),
            at: 0
        )
        if recentEvents.count > Self.maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - Self.maxRecentEvents)
        }
    }

    /// SSDP 用 POSIX UDP socket ── Network.framework 的 NWConnectionGroup
    /// / NWListener UDP 在 iOS 上同时绑 1900 端口的 multicast + unicast 时
    /// 有已知问题, 实测一个 M-SEARCH 都收不到 (见 8b1da7c)。退回 BSD socket:
    /// 一个 fd 绑 INADDR_ANY:1900, 同时通过 IP_ADD_MEMBERSHIP 加入
    /// 239.255.255.250, multicast 和 unicast M-SEARCH 都能投递到 read source。
    private var ssdpSocket: Int32 = -1
    private var ssdpReadSource: DispatchSourceRead?
    private var httpListener: NWListener?
    /// 半开连接防护: 凑齐请求头前的 idle 超时 + 并发连接上限, 防 LAN 端
    /// slow-loris 式只 connect 不发完整请求头拖死 fd。
    private static let httpHeaderTimeout: TimeInterval = 12
    private static let maxHTTPConnections = 16
    private var activeHTTPConnections = 0
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
    private struct RemoteMediaProbe: Sendable {
        let fileSize: Int64
        let supportsRange: Bool
        let detail: String
    }
    private var currentTransportItem: TransportItem?
    private var nextTransportItem: TransportItem?
    private var activeControllerID: String?
    private var transportPlaybackTask: Task<Void, Never>?

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
        #if os(iOS)
        let device = UIDevice.current.name
        #else
        let device = Host.current().localizedName ?? "Mac"
        #endif
        self.friendlyName = "猿音 · \(device)"
    }

    // MARK: - Lifecycle

    /// 后台保活开关。开了之后 audio session 会被静默音流撑住, app 即使没在
    /// 播音乐, 退到后台后 NWListener 也能继续接 SSDP/control。代价: 锁屏 /
    /// 控制中心会显示猿音"在播", 电量略增 ── footer 里写明。
    /// 状态走 @AppStorage 由 UI 侧持久, 这里只暴露 set 入口让设置页 onChange 调。
    private(set) var keepAliveInBackground = false

    func setKeepAliveInBackground(_ enabled: Bool) {
        keepAliveInBackground = enabled
        syncKeepAliveState()
    }

    /// 根据 (DLNA running, keepAlive 开关, 真歌是否在播) 三个状态调度
    /// AudioEngine 的 silence keepAlive。真歌在播时不开 (主路径已撑 session,
    /// 没必要双管齐下); 真歌停了再开。
    private func syncKeepAliveState() {
        let shouldKeepAlive = isRunning && keepAliveInBackground && !player.isPlaying
        if shouldKeepAlive {
            player.audioEngine.startSilenceKeepAlive()
        } else {
            player.audioEngine.stopSilenceKeepAlive()
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            try startHTTP()
            try startSSDP()
            syncRenderingStateFromEngine()
            installPlayerObservation()
            isRunning = true
            statusText = String(localized: "dlna_status_listening")
            syncKeepAliveState()
            // 启动 Controller 侧的主动设备发现循环 ── 跟 NOTIFY alive 一样
            // 前 60s 频繁 (3s/次) 让用户进 UI 就能立刻看到设备, 之后改 5min
            // 兜底。每轮也顺手 prune 30 分钟没听到的 stale renderer。
            discoveryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                await MainActor.run { self?.refreshRemoteRenderers() }
                var fastTicks = 0
                while !Task.isCancelled {
                    let delay = fastTicks < 20 ? 3 : 300
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { break }
                    await MainActor.run { self?.refreshRemoteRenderers() }
                    fastTicks += 1
                }
            }
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
            playTransportItem(next)
        }
        // 真歌 play/pause 状态变了, 重新评估要不要开静音保活 (真歌在播时关掉
        // 省电, 真歌停了再撑住 session 让 NWListener 在后台不挂)。
        syncKeepAliveState()
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
        discoveryTask?.cancel(); discoveryTask = nil
        playerObservationToken?.cancel(); playerObservationToken = nil
        transportPlaybackTask?.cancel(); transportPlaybackTask = nil
        subscriptions.removeAll()
        connectedDevices.removeAll()
        discoveredRenderers.removeAll()
        activeControllerID = nil
        ssdpReadSource?.cancel()  // cancel handler 里 close(fd)
        ssdpReadSource = nil
        ssdpSocket = -1
        httpListener?.cancel(); httpListener = nil
        activeHTTPConnections = 0
        isRunning = false
        statusText = ""
        // 关 DLNA 等于不再需要后台接推送, 顺手把静音保活也停掉省电。
        player.audioEngine.stopSilenceKeepAlive()
    }

    // MARK: - Controller (主动发现 LAN 内的 MediaRenderer)

    /// 主动 M-SEARCH 让 LAN 内的 renderer 立即响应 ── 比等 NOTIFY alive 快得多
    /// (alive 周期 ~5min)。控制点 enter UI 时调一次刷新, 后续 periodic 兜底。
    func refreshRemoteRenderers() {
        sendMSearch(target: "urn:schemas-upnp-org:device:MediaRenderer:1")
        // ssdp:all 也撒一遍, 兼容某些设备只对 ssdp:all 响应不对具体 ST 响应
        sendMSearch(target: "ssdp:all")
        pruneStaleRenderers()
    }

    private func sendMSearch(target: String) {
        guard ssdpSocket >= 0 else { return }
        let payload = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: \(target)\r
        \r

        """
        guard let data = payload.data(using: .utf8) else { return }
        sendUDP(data: data, toHost: "239.255.255.250", toPort: Self.ssdpPort.rawValue)
    }

    /// 200 OK (我们 M-SEARCH 的响应) 和 NOTIFY (别人主动广播) 共用同一解析:
    /// 都带 LOCATION / USN / NT-or-ST。byebye 时移除, 其他都当作 alive 处理。
    private func handleDiscoveryMessage(_ raw: String, fromHost host: String) {
        let nts = headerValue("nts", in: raw)?.lowercased()
        let usn = headerValue("usn", in: raw) ?? ""
        let udn = extractUDN(from: usn)
        guard !udn.isEmpty else { return }

        if nts == "ssdp:byebye" {
            if discoveredRenderers.removeValue(forKey: udn) != nil {
                logEvent(.discovery, "Renderer byebye \(udn.suffix(8))")
            }
            return
        }

        // alive / unicast 响应路径 ── 只关心 MediaRenderer 设备。
        let nt = headerValue("nt", in: raw) ?? headerValue("st", in: raw) ?? ""
        guard nt.lowercased().contains("mediarenderer") else {
            // ssdp:all 会撒来一堆别的 device type, 我们只挑 MediaRenderer
            // (但 rootdevice / uuid 的响应过来时 nt 不带 MediaRenderer, 此时
            // 看后续的具体 service 响应, 这里直接 ignore 避免误收一堆 IGD/AVR 等)
            return
        }
        guard let locationStr = headerValue("location", in: raw),
              let location = URL(string: locationStr) else { return }

        if discoveredRenderers[udn] != nil {
            discoveredRenderers[udn]?.lastSeen = Date()
            return   // 已经拉过 device.xml, 不重复
        }
        // 占位先存, 后续 fetch 完整描述再补字段
        discoveredRenderers[udn] = RemoteRenderer(
            udn: udn,
            friendlyName: host,
            host: host,
            location: location,
            lastSeen: Date()
        )
        logEvent(.discovery, "Renderer discovered \(udn.suffix(8)) → fetching \(location.absoluteString)")
        Task { [weak self] in
            await self?.fetchDeviceDescription(udn: udn, location: location)
        }
    }

    /// SSDP USN 形如 "uuid:60dbae9b-...::urn:schemas-upnp-org:device:MediaRenderer:1",
    /// 取 :: 前的 uuid:xxx 段作为 UDN 索引。
    private func extractUDN(from usn: String) -> String {
        if let range = usn.range(of: "::") {
            return String(usn[..<range.lowerBound])
        }
        return usn
    }

    /// 异步拉 device.xml 解析出 friendlyName / serviceList controlURL / sinkProtocolInfo,
    /// 失败把这台 renderer 移除 (后续 alive 会重新触发)。
    private func fetchDeviceDescription(udn: String, location: URL) async {
        do {
            let (data, _) = try await discoverySession.data(from: location)
            guard let xml = String(data: data, encoding: .utf8) else { return }
            let parsed = parseDeviceDescription(xml, baseURL: location)
            await MainActor.run {
                guard var existing = discoveredRenderers[udn] else { return }
                existing.friendlyName = parsed.friendlyName ?? existing.friendlyName
                existing.avTransportControlURL = parsed.avTransportControl
                existing.renderingControlControlURL = parsed.renderingControlControl
                existing.connectionManagerControlURL = parsed.connectionManagerControl
                existing.avTransportEventURL = parsed.avTransportEvent
                existing.renderingControlEventURL = parsed.renderingControlEvent
                existing.manufacturer = parsed.manufacturer
                existing.modelName = parsed.modelName
                discoveredRenderers[udn] = existing
                logEvent(.discovery, "Renderer ready '\(existing.friendlyName)' (\(udn.suffix(8)))")
            }
        } catch {
            await MainActor.run {
                discoveredRenderers.removeValue(forKey: udn)
                logEvent(.error, "device.xml fetch failed \(udn.suffix(8)): \(error.localizedDescription)")
            }
        }
    }

    /// 极简 XML scrape: 不用 XMLParser, 用 substring 找 <friendlyName> / <service>。
    /// device.xml 结构简单稳定, 没必要起完整 SAX。controlURL / eventSubURL 是
    /// 相对路径, 跟 BASE URL 合并成绝对。
    private struct ParsedDeviceDescription {
        var friendlyName: String?
        var manufacturer: String?
        var modelName: String?
        var avTransportControl: URL?
        var renderingControlControl: URL?
        var connectionManagerControl: URL?
        var avTransportEvent: URL?
        var renderingControlEvent: URL?
    }

    private func parseDeviceDescription(_ xml: String, baseURL: URL) -> ParsedDeviceDescription {
        var result = ParsedDeviceDescription()
        result.friendlyName = extract(tag: "friendlyName", from: xml)
        result.manufacturer = extract(tag: "manufacturer", from: xml)
        result.modelName = extract(tag: "modelName", from: xml)

        // 按 <service> 块拆分, 每块里找 serviceType + controlURL + eventSubURL
        var searchRange = xml.startIndex..<xml.endIndex
        while let openRange = xml.range(of: "<service>", range: searchRange),
              let closeRange = xml.range(of: "</service>", range: openRange.upperBound..<xml.endIndex) {
            let block = String(xml[openRange.upperBound..<closeRange.lowerBound])
            let serviceType = extract(tag: "serviceType", from: block) ?? ""
            let controlRel = extract(tag: "controlURL", from: block) ?? ""
            let eventRel = extract(tag: "eventSubURL", from: block) ?? ""
            let controlURL = URL(string: controlRel, relativeTo: baseURL)?.absoluteURL
            let eventURL = URL(string: eventRel, relativeTo: baseURL)?.absoluteURL
            if serviceType.lowercased().contains("avtransport") {
                result.avTransportControl = controlURL
                result.avTransportEvent = eventURL
            } else if serviceType.lowercased().contains("renderingcontrol") {
                result.renderingControlControl = controlURL
                result.renderingControlEvent = eventURL
            } else if serviceType.lowercased().contains("connectionmanager") {
                result.connectionManagerControl = controlURL
            }
            searchRange = closeRange.upperBound..<xml.endIndex
        }
        return result
    }

    /// 超过 max-age (1800s) 没听到任何 alive / 响应就移除 ── 控制点也不能让
    /// 一堆已经关机的设备一直挂在 picker 上。
    private func pruneStaleRenderers() {
        let cutoff = Date().addingTimeInterval(-1800)
        let stale = discoveredRenderers.filter { $0.value.lastSeen < cutoff }.map(\.key)
        for udn in stale {
            discoveredRenderers.removeValue(forKey: udn)
            logEvent(.discovery, "Renderer prune stale \(udn.suffix(8))")
        }
    }

    // MARK: - SSDP

    private func startSSDP() throws {
        // 一个 UDP socket 同时收 multicast(239.255.255.250) 和 unicast(自机
        // 任意 IP) 到 1900 端口的包 ── BSD socket 标准玩法, 跟 iOS 上
        // NWConnectionGroup/NWListener UDP 同绑同端口的兼容性问题彻底解耦。
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        // SO_REUSEADDR + SO_REUSEPORT ── 跟其它可能存在的 SSDP-aware 进程共存
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes,
                       socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = Self.ssdpPort.rawValue.bigEndian
        bindAddr.sin_addr.s_addr = in_addr_t(0)   // INADDR_ANY
        let bindResult = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey: "bind(0.0.0.0:1900) failed errno=\(e)"])
        }

        // IP_ADD_MEMBERSHIP ── 加入 239.255.255.250 组。imr_interface 设
        // INADDR_ANY 让内核挑路由(通常是默认上行接口)。失败不致命,
        // 退化为只有 unicast SSDP 可用。
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
        mreq.imr_interface.s_addr = in_addr_t(0)
        let joinResult = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq,
                                    socklen_t(MemoryLayout<ip_mreq>.size))
        if joinResult != 0 {
            logEvent(.error, "IP_ADD_MEMBERSHIP failed errno=\(errno)")
        }

        // multicast TTL + 关 loopback ── 跨网段 4 跳够用, 自己发的 NOTIFY
        // 不需要再回到自己 (会触发 handleSSDPRead 浪费 CPU)。
        var ttl: UInt8 = 4
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl,
                       socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 0
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop,
                       socklen_t(MemoryLayout<UInt8>.size))

        ssdpSocket = fd

        // DispatchSourceRead 在 main queue 上等 readable; recvfrom 立即返回。
        // setCancelHandler 里 close(fd), 保证 socket 跟 source 同生命周期。
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleSSDPRead()
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        ssdpReadSource = source

        logEvent(.discovery, "SSDP socket bound UDP/1900 + joined 239.255.255.250")

        // 启动 NOTIFY alive 广播循环。前 60s 内每 3s 发一次 (新加入网络
        // 的控制点能尽快看到我们),之后改成每 5 分钟,跟 max-age=1800
        // 的标准建议(发送间隔 < max-age/2)对齐。
        notifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run { self?.sendNotifyBatch(isAlive: true) }
            var fastTicks = 0
            while !Task.isCancelled {
                let delay = fastTicks < 20 ? 3 : 300
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.sendNotifyBatch(isAlive: true) }
                fastTicks += 1
            }
        }
    }

    private var interestedSSDPTargets: [String] {
        (["ssdp:all"] + usnTypes).map { $0.lowercased() }
    }

    /// DispatchSource 触发时调 recvfrom 取一个 UDP 包 ── UDP datagram 边界
    /// 明确, 每次 read 一个完整 M-SEARCH (或 NOTIFY, 但我们 ignore)。
    private func handleSSDPRead() {
        guard ssdpSocket >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            withUnsafeMutablePointer(to: &src) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.recvfrom(ssdpSocket, buf.baseAddress, buf.count, 0, saPtr, &srcLen)
                }
            }
        }
        guard n > 0 else { return }
        let data = Data(buffer[0..<n])
        guard let request = String(data: data, encoding: .utf8) else { return }
        let host = Self.ipString(from: src.sin_addr)
        let port = UInt16(bigEndian: src.sin_port)
        handleSSDPDatagram(request, fromHost: host, fromPort: port)
    }

    /// 解析 M-SEARCH, 命中我们 ST 时按 UPnP/AV 规范 unicast 回 6 条 200 OK
    /// (rootdevice / uuid / device:MediaRenderer:1 / 3 个 service:*) ──
    /// 控制点按 USN 去重。
    ///
    /// 同一个 SSDP socket 三种入流量按 message 起始行分发:
    /// - "M-SEARCH * HTTP/1.1" → 别人在扫, 走 renderer 回 200 OK
    /// - "HTTP/1.1 200 OK"     → 我们之前发出的 M-SEARCH 的响应, 走 Controller 路径
    ///                           解析 LOCATION + ST, 异步拉 device.xml 进 discoveredRenderers
    /// - "NOTIFY * HTTP/1.1"   → 别人广播 alive/byebye, 走 Controller 路径同样处理
    private func handleSSDPDatagram(_ request: String, fromHost host: String, fromPort port: UInt16) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if firstLine.hasPrefix("M-SEARCH") {
            let lower = request.lowercased()
            guard interestedSSDPTargets.contains(where: { lower.contains($0) }) else { return }
            let st = headerValue("st", in: request) ?? "?"
            logEvent(.discovery, "M-SEARCH from \(host):\(port) (ST=\(st)) — replied")
            sendSSDPReplies(toHost: host, toPort: port)
        } else if firstLine.hasPrefix("HTTP/1.1 200") || firstLine.hasPrefix("NOTIFY") {
            handleDiscoveryMessage(request, fromHost: host)
        }
    }

    private func sendSSDPReplies(toHost host: String, toPort port: UInt16) {
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
            if let data = response.data(using: .utf8) {
                sendUDP(data: data, toHost: host, toPort: port)
            }
        }
    }

    /// NOTIFY ssdp:alive / byebye ── 周期性 multicast 广播当前在线状态。
    /// stop() 时同步发一遍 byebye 让控制点立刻从列表移除, 不用等 max-age 过期。
    private func sendNotifyBatch(isAlive: Bool) {
        guard ssdpSocket >= 0, let location = httpLocation() else { return }
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
            if let data = notify.data(using: .utf8) {
                sendUDP(data: data, toHost: "239.255.255.250",
                        toPort: Self.ssdpPort.rawValue)
            }
        }
    }

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

    private func sendUDP(data: Data, toHost host: String, toPort port: UInt16) {
        guard ssdpSocket >= 0 else { return }
        var dest = sockaddr_in()
        dest.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr(host)
        _ = data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Int in
            withUnsafePointer(to: &dest) { destPtr -> Int in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr -> Int in
                    Darwin.sendto(ssdpSocket, rawBuf.baseAddress, rawBuf.count, 0,
                                  saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func ipString(from addr: in_addr) -> String {
        var copy = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
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
                    // NWListener 在网络切换后进 .failed 不会自愈; SSDP 仍在广播
                    // 指向这个死 server 的 LOCATION, 必须重启 HTTP 监听 (固定端口
                    // 49152, LOCATION 不变), 否则控制点拉 device.xml 必失败。
                    self?.restartHTTPAfterFailure(error: error)
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

    /// HTTP control listener 失效后的自愈: cancel 旧 listener, 在同端口重建。
    /// 重建失败则把服务标记为出错状态, 让 UI 能反映 "投不出去" 而非静默假活。
    private func restartHTTPAfterFailure(error: NWError) {
        guard isRunning else { return }
        httpListener?.cancel(); httpListener = nil
        // 旧 listener 已接受但未收尾的连接, 其递减 Task 可能永不触发(NWConnection 在
        // 网络抖动下可能静默失效、不进 .cancelled/.failed)。重建前归零, 否则计数只增
        // 不减、累积到上限后永久拒绝新连接, 控制点再也连不上且无自愈。
        activeHTTPConnections = 0
        do {
            try startHTTP()
            logEvent(.event, "HTTP control server restarted after failure")
        } catch {
            isRunning = false
            statusText = String(format: String(localized: "dlna_status_error_format"), error.localizedDescription)
            logEvent(.error, "HTTP control server restart failed: \(error.localizedDescription)")
        }
    }

    private func handleHTTPConnection(_ connection: NWConnection) {
        // 并发连接上限: 超过直接 cancel, 防 LAN 端无限累积 fd。
        guard activeHTTPConnections < Self.maxHTTPConnections else {
            connection.cancel(); return
        }
        activeHTTPConnections += 1
        // 半开连接 idle 超时: 凑齐请求头之前若超时未推进就 cancel; header 收齐后
        // 在 receiveHTTPRequest 里停掉 (SOAP body / GENA 处理可能稍长)。
        let headerTimer = DispatchSource.makeTimerSource(queue: .main)
        headerTimer.schedule(deadline: .now() + Self.httpHeaderTimeout)
        headerTimer.setEventHandler { [weak connection] in
            dlnaLog.debug("HTTP connection header timeout, closing")
            connection?.cancel()
        }
        headerTimer.resume()
        // 连接终态统一扣并发计数 + 停 timer, 只走这一处避免漏算。
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                headerTimer.cancel()
                Task { @MainActor in
                    if let self, self.activeHTTPConnections > 0 { self.activeHTTPConnections -= 1 }
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveHTTPRequest(on: connection, buffer: Data(), headerTimer: headerTimer)
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data, headerTimer: DispatchSourceTimer) {
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
                // 请求头/体已收齐, idle timer 使命结束。
                headerTimer.cancel()
                Task { @MainActor in await self.routeHTTP(text, connection: connection) }
            } else if isComplete {
                connection.cancel()
            } else {
                Task { @MainActor in self.receiveHTTPRequest(on: connection, buffer: nextBuffer, headerTimer: headerTimer) }
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
        guard contentLength >= 0 else { return nil }
        let (totalLength, overflow) = headerEnd.addingReportingOverflow(contentLength)
        guard !overflow, totalLength >= headerEnd, data.count >= totalLength else { return nil }
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
        return max(0, min(100, Double(volume * 100).rounded().finiteInt()))
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
            playTransportItem(item)
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
            if player.isLoading {
                // A pushed URL is already opening; acknowledge quickly and
                // let the in-flight playback task finish.
            } else if !player.isPlaying, let current = currentTransportItem, player.currentSong == nil {
                playTransportItem(current)
            } else if !player.isPlaying {
                player.resume()
            }
            await sendSOAP(action: "Play", body: "", on: connection)
        case "Pause":
            if player.isPlaying { player.togglePlayPause() }
            await sendSOAP(action: "Pause", body: "", on: connection)
        case "Stop":
            transportPlaybackTask?.cancel(); transportPlaybackTask = nil
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
            playTransportItem(next)
            await sendSOAP(action: "Next", body: "", on: connection)
        case "Previous":
            await sendSOAPError(code: 711, description: "Transition not available", on: connection)
        case "GetTransportInfo":
            let state: String
            if player.isPlaying {
                state = "PLAYING"
            } else if player.isLoading || transportPlaybackTask != nil {
                state = "TRANSITIONING"
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

    private func playTransportItem(_ item: TransportItem) {
        currentTransportItem = item
        statusText = String(format: String(localized: "dlna_status_playing_format"), item.title)
        notifyAllSubscribers()

        transportPlaybackTask?.cancel()
        transportPlaybackTask = Task { @MainActor [weak self, item] in
            guard let self else { return }
            let started = await self.playRemote(url: item.url, title: item.title, artist: item.artist)
            guard !Task.isCancelled, self.currentTransportItem?.uri == item.uri else { return }
            self.transportPlaybackTask = nil
            if started {
                self.statusText = String(format: String(localized: "dlna_status_playing_format"), item.title)
            } else {
                self.statusText = String(format: String(localized: "dlna_status_error_format"), "Playback failed")
                self.logEvent(.error, "Playback failed to start for \(item.title)")
            }
            self.notifyAllSubscribers()
        }
    }

    /// 创建一个临时 Song 喂给 player.play(song:from:)。sourceID 用 "dlna"
    /// 标识来源,filePath 存 URL ── 走的是 AudioPlayerService 的 "from URL"
    /// 分支,跟我们的 MusicSource 系统完全独立,不会污染库。
    private func playRemote(url: URL, title: String, artist: String?) async -> Bool {
        let probe = await probeRemoteMedia(url: url)
        if !probe.detail.isEmpty {
            logEvent(.control, "Media probe \(url.host ?? url.scheme ?? "?"): \(probe.detail)")
        }
        guard !Task.isCancelled else { return false }

        let song = Song(
            id: "dlna:\(UUID().uuidString)",
            title: title,
            artistName: artist,
            duration: 0,
            fileFormat: AudioFormat.from(fileExtension: url.pathExtension) ?? .mp3,
            filePath: url.absoluteString,
            sourceID: "dlna",
            fileSize: probe.supportsRange ? probe.fileSize : 0
        )
        await player.play(song: song, from: url)
        return player.currentSong?.id == song.id && player.isPlaying
    }

    private func probeRemoteMedia(url: URL) async -> RemoteMediaProbe {
        if url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return RemoteMediaProbe(fileSize: size, supportsRange: false, detail: size > 0 ? "local size=\(size / 1024)KB" : "")
        }

        guard url.scheme == "http" || url.scheme == "https" else {
            return RemoteMediaProbe(fileSize: 0, supportsRange: false, detail: "")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 2
        // A delegate-backed URLSession strongly retains its delegate and never
        // deallocates until explicitly invalidated, so a per-cast session would
        // leak both the session and its SmartSSLDelegate. invalidateAndCancel()
        // also tears down any task still in flight — notably the probeRange 200
        // branch, where the server ignored Range and we abandoned the AsyncBytes
        // stream (the underlying connection would otherwise hang until timeout).
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        if let range = await probeRange(url: url, session: session) {
            return range
        }

        if let head = await probeHead(url: url, session: session) {
            return head
        }

        return RemoteMediaProbe(fileSize: 0, supportsRange: false, detail: "no range/length response; using progressive fallback")
    }

    private func probeRange(url: URL, session: URLSession) async -> RemoteMediaProbe? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 206:
                let size = parseContentRangeTotal(responseHeader("Content-Range", in: http))
                    ?? contentLength(from: http)
                guard let size, size > 0 else {
                    return RemoteMediaProbe(fileSize: 0, supportsRange: false, detail: "range OK but total length unknown")
                }
                return RemoteMediaProbe(fileSize: size, supportsRange: true, detail: "range OK size=\(size / 1024)KB")
            case 200:
                let size = contentLength(from: http) ?? 0
                return RemoteMediaProbe(fileSize: size, supportsRange: false, detail: "server ignored Range status=200 size=\(size / 1024)KB")
            default:
                return RemoteMediaProbe(fileSize: 0, supportsRange: false, detail: "range probe HTTP \(http.statusCode)")
            }
        } catch {
            logEvent(.error, "Media range probe failed for \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    private func probeHead(url: URL, session: URLSession) async -> RemoteMediaProbe? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            let size = contentLength(from: http) ?? 0
            let acceptsRange = responseHeader("Accept-Ranges", in: http)?
                .localizedCaseInsensitiveContains("bytes") == true
            guard (200...299).contains(http.statusCode), size > 0 else {
                return RemoteMediaProbe(fileSize: 0, supportsRange: false, detail: "HEAD HTTP \(http.statusCode)")
            }
            return RemoteMediaProbe(
                fileSize: size,
                supportsRange: acceptsRange,
                detail: acceptsRange ? "HEAD range advertised size=\(size / 1024)KB" : "HEAD size=\(size / 1024)KB without range"
            )
        } catch {
            logEvent(.error, "Media HEAD probe failed for \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return responseHeader("Content-Length", in: response)
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func parseContentRangeTotal(_ header: String?) -> Int64? {
        guard let header,
              let total = header.split(separator: "/").last,
              total != "*" else { return nil }
        return Int64(total.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func responseHeader(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    // MARK: - XML helpers

    private func deviceDescriptionXML() -> String {
        // X_DLNADOC 声明 DMR-1.50 兼容 ── 某些控制点 (Synology Audio Station、
        // 部分日韩品牌 AVR) 只列出明确带这个标记的 renderer; X_DLNACAP 留空
        // 表示没有额外可选能力, 但要存在这个 tag 才符合 DLNA 规范。
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMR-1.50</dlna:X_DLNADOC>
            <dlna:X_DLNACAP xmlns:dlna="urn:schemas-dlna-org:device-1-0"></dlna:X_DLNACAP>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>\(xmlEscape(friendlyName))</friendlyName>
            <manufacturer>Welape</manufacturer>
            <manufacturerURL>https://welape.com</manufacturerURL>
            <modelDescription>Primuse Media Renderer</modelDescription>
            <modelName>Primuse</modelName>
            <modelNumber>1.0</modelNumber>
            <modelURL>https://welape.com/primuse</modelURL>
            <serialNumber>\(deviceUUID.prefix(12))</serialNumber>
            <UDN>uuid:\(deviceUUID)</UDN>
            <UPC>000000000000</UPC>
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

// MARK: - Remote Renderer Controller (Controller 侧 SOAP 客户端)

/// 包住一台远端 MediaRenderer, 提供 SetAVTransportURI / Play / Pause / Stop /
/// Seek / Next / SetVolume / SetMute / GetPositionInfo 几个常用调用。每个调用
/// 拼 SOAP envelope 走 POST 到 renderer.<service>ControlURL。
///
/// 状态 (currentTime / duration / isPlaying) 不在这里 cache, caller (投屏 UI
/// view model) 自己 1Hz 轮询 GetPositionInfo + GetTransportInfo 保持同步。
@MainActor
final class RemoteRendererController {
    let renderer: RemoteRenderer
    private let session: URLSession

    private static let avTransportNS = "urn:schemas-upnp-org:service:AVTransport:1"
    private static let renderingControlNS = "urn:schemas-upnp-org:service:RenderingControl:1"

    init(renderer: RemoteRenderer) {
        self.renderer = renderer
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    deinit {
        // Let any in-flight SOAP request complete, then release the session so
        // it doesn't outlive this controller. finishTasksAndInvalidate() is
        // thread-safe and safe to call from deinit (no async hop required).
        session.finishTasksAndInvalidate()
    }

    // MARK: AVTransport

    func setAVTransportURI(uri: String, title: String, artist: String?) async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let didl = Self.didlLite(uri: uri, title: title, artist: artist)
        let body = """
        <u:SetAVTransportURI xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        <CurrentURI>\(Self.xmlEscape(uri))</CurrentURI>
        <CurrentURIMetaData>\(Self.xmlEscape(didl))</CurrentURIMetaData>
        </u:SetAVTransportURI>
        """
        _ = try await postSOAP(controlURL: url, action: "SetAVTransportURI",
                               namespace: Self.avTransportNS, body: body)
    }

    func play() async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:Play xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        <Speed>1</Speed>
        </u:Play>
        """
        _ = try await postSOAP(controlURL: url, action: "Play",
                               namespace: Self.avTransportNS, body: body)
    }

    func pause() async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:Pause xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        </u:Pause>
        """
        _ = try await postSOAP(controlURL: url, action: "Pause",
                               namespace: Self.avTransportNS, body: body)
    }

    func stop() async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:Stop xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        </u:Stop>
        """
        _ = try await postSOAP(controlURL: url, action: "Stop",
                               namespace: Self.avTransportNS, body: body)
    }

    func next() async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:Next xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        </u:Next>
        """
        _ = try await postSOAP(controlURL: url, action: "Next",
                               namespace: Self.avTransportNS, body: body)
    }

    func seek(toSeconds seconds: TimeInterval) async throws {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:Seek xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        <Unit>REL_TIME</Unit>
        <Target>\(Self.formatTime(seconds))</Target>
        </u:Seek>
        """
        _ = try await postSOAP(controlURL: url, action: "Seek",
                               namespace: Self.avTransportNS, body: body)
    }

    /// 返回 (relTime, duration), 单位秒。失败抛错。
    func getPositionInfo() async throws -> (currentTime: TimeInterval, duration: TimeInterval) {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:GetPositionInfo xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        </u:GetPositionInfo>
        """
        let resp = try await postSOAP(controlURL: url, action: "GetPositionInfo",
                                      namespace: Self.avTransportNS, body: body)
        let cur = Self.parseTime(Self.extract(tag: "RelTime", from: resp) ?? "00:00:00")
        let dur = Self.parseTime(Self.extract(tag: "TrackDuration", from: resp) ?? "00:00:00")
        return (cur, dur)
    }

    /// 返回 transport state ── "PLAYING" / "PAUSED_PLAYBACK" / "STOPPED" / "TRANSITIONING" 等。
    func getTransportInfo() async throws -> String {
        guard let url = renderer.avTransportControlURL else { throw missingService("AVTransport") }
        let body = """
        <u:GetTransportInfo xmlns:u="\(Self.avTransportNS)">
        <InstanceID>0</InstanceID>
        </u:GetTransportInfo>
        """
        let resp = try await postSOAP(controlURL: url, action: "GetTransportInfo",
                                      namespace: Self.avTransportNS, body: body)
        return Self.extract(tag: "CurrentTransportState", from: resp) ?? "STOPPED"
    }

    // MARK: RenderingControl

    func setVolume(_ percent: Int) async throws {
        guard let url = renderer.renderingControlControlURL else { throw missingService("RenderingControl") }
        let clamped = max(0, min(100, percent))
        let body = """
        <u:SetVolume xmlns:u="\(Self.renderingControlNS)">
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredVolume>\(clamped)</DesiredVolume>
        </u:SetVolume>
        """
        _ = try await postSOAP(controlURL: url, action: "SetVolume",
                               namespace: Self.renderingControlNS, body: body)
    }

    func setMute(_ muted: Bool) async throws {
        guard let url = renderer.renderingControlControlURL else { throw missingService("RenderingControl") }
        let body = """
        <u:SetMute xmlns:u="\(Self.renderingControlNS)">
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredMute>\(muted ? 1 : 0)</DesiredMute>
        </u:SetMute>
        """
        _ = try await postSOAP(controlURL: url, action: "SetMute",
                               namespace: Self.renderingControlNS, body: body)
    }

    func getVolume() async throws -> Int {
        guard let url = renderer.renderingControlControlURL else { throw missingService("RenderingControl") }
        let body = """
        <u:GetVolume xmlns:u="\(Self.renderingControlNS)">
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        </u:GetVolume>
        """
        let resp = try await postSOAP(controlURL: url, action: "GetVolume",
                                      namespace: Self.renderingControlNS, body: body)
        return Int(Self.extract(tag: "CurrentVolume", from: resp) ?? "0") ?? 0
    }

    // MARK: Internals

    private func postSOAP(controlURL: URL, action: String, namespace: String, body: String) async throws -> String {
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(namespace)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.setValue("Primuse/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        \(body)
        </s:Body>
        </s:Envelope>
        """
        req.httpBody = envelope.data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Primuse.DLNA", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            let snippet = text.prefix(200)
            throw NSError(domain: "Primuse.DLNA", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "SOAP \(action) → HTTP \(http.statusCode): \(snippet)"])
        }
        return text
    }

    private func missingService(_ name: String) -> NSError {
        NSError(domain: "Primuse.DLNA", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(renderer.friendlyName) does not expose \(name) service"])
    }

    // MARK: Static helpers (无 instance 依赖, 跟 DLNARendererService 内部的 xmlEscape/extract 平行实现)

    private static func didlLite(uri: String, title: String, artist: String?) -> String {
        var artistTag = ""
        if let artist {
            artistTag = "<upnp:artist>\(xmlEscape(artist))</upnp:artist><dc:creator>\(xmlEscape(artist))</dc:creator>"
        }
        // res protocolInfo 用宽 wildcard ── 不知道目标格式时大多数 renderer
        // 仍能接受 (会按 URL 扩展名 / Content-Type 自己识别)。具体格式由
        // server (我们这边 / NAS) 的 HEAD 返回 Content-Type 决定。
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="0" parentID="0" restricted="1">
        <dc:title>\(xmlEscape(title))</dc:title>
        \(artistTag)
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>
        <res protocolInfo="http-get:*:*:*">\(xmlEscape(uri))</res>
        </item>
        </DIDL-Lite>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func extract(tag: String, from xml: String) -> String? {
        let decoded = xml
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let open = "<\(tag)"
        guard let openRange = decoded.range(of: open) else { return nil }
        guard let closeRange = decoded.range(of: "</\(tag)>",
                                              range: openRange.upperBound..<decoded.endIndex) else { return nil }
        let afterOpen = decoded[openRange.upperBound..<closeRange.lowerBound]
        guard let bracket = afterOpen.firstIndex(of: ">") else { return nil }
        return String(afterOpen[afterOpen.index(after: bracket)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00:00" }
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func parseTime(_ s: String) -> TimeInterval {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0]
    }
}

// MARK: - DLNA Media Server (给远端 renderer 提供本地音频文件)

/// 本地 / 已缓存到 iPhone 的歌投到外部 DLNA renderer 时, renderer 需要一个
/// 可达 HTTP URL 去拉文件。本 server 注册临时 token → 本地文件映射, 返回
/// http://<iphone-ip>:<port>/<token>/<name>.ext, renderer 拿到后用 HEAD + Range
/// GET 拉数据。
///
/// 跟 Renderer 的 49152 HTTP server (服务 device.xml / SOAP) 分开走 49160, 避免
/// 端口冲突 + 概念混淆。range 是 DLNA 1.0 必备 ── renderer 经常先 HEAD 拿
/// Content-Length 再用 Range 起步 / 跳秒, 必须支持。
@MainActor
final class DLNAMediaServer {
    static let shared = DLNAMediaServer()

    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private static let preferredPort: UInt16 = 49160
    /// listener/connection 与文件读取都跑在这个独立串行 queue, 不占 main。
    /// 只有要回写 entries / 状态时才 hop 回 @MainActor。
    nonisolated private static let networkQueue = DispatchQueue(label: "com.welape.yuanyin.dlna.mediaserver")
    /// 半开连接防护: 凑齐请求头前的 idle 超时 + 并发连接上限, 防 LAN 端
    /// slow-loris 式拖死 fd。
    private static let headerTimeout: TimeInterval = 12
    private static let maxConnections = 16
    private var activeConnections = 0

    /// token → 本地文件 + 过期时间。10 分钟过期, renderer 拉完音频文件不会
    /// 再用同一 URL, 短过期避免历史 token 滥用 + 重启清空。
    private struct Entry {
        let localURL: URL
        let mimeType: String
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]

    private init() {}

    func ensureStarted() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        var lastError: Error?
        // 49160-49169 顺序探, 哪个能 bind 用哪个
        for portRaw in Self.preferredPort..<(Self.preferredPort + 10) {
            guard let port = NWEndpoint.Port(rawValue: portRaw) else { continue }
            do {
                let l = try NWListener(using: params, on: port)
                l.stateUpdateHandler = { [weak self] state in
                    if case .failed(let e) = state {
                        plog("[DLNA] MediaServer listener failed: \(e.localizedDescription)")
                        // 网络切换后 NWListener 进 failed 不会自愈, 必须把
                        // listener 置 nil 让下次 registerFile→ensureStarted 重建,
                        // 否则 registerFile 仍发出指向死 server 的 URL, 投放静默失效。
                        Task { @MainActor in self?.invalidateListener() }
                    }
                }
                l.newConnectionHandler = { [weak self] conn in
                    Task { @MainActor in self?.handleConnection(conn) }
                }
                l.start(queue: Self.networkQueue)
                listener = l
                boundPort = portRaw
                plog("[DLNA] MediaServer bound TCP/\(portRaw)")
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "Primuse.DLNA", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "All MediaServer ports 49160-49169 in use"])
    }

    func stop() {
        listener?.cancel(); listener = nil
        boundPort = 0
        activeConnections = 0
        entries.removeAll()
    }

    /// listener 进入 .failed 后调用: cancel 并清空, 让下次 ensureStarted 重建。
    /// entries 保留 (token 仍可能被即将的重建 server 复用拉流)。
    private func invalidateListener() {
        listener?.cancel(); listener = nil
        boundPort = 0
        // 同 DLNARendererService: 未收尾连接的递减 Task 可能永不触发, 重建前归零
        // 避免计数累积到上限后永久拒绝新连接。
        activeConnections = 0
    }

    /// 注册一个本地文件给远端 renderer 拉。返回的 URL 仅 10 分钟内有效,
    /// renderer 一般 SetAVTransportURI 后立刻 HEAD/GET, 5 分钟兜底够用。
    /// suggestedName 仅作 URL path 装饰让对方 GUI 能显示, 不影响真实定位。
    func registerFile(localURL: URL, suggestedName: String) throws -> URL {
        try ensureStarted()
        pruneExpired()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let mime = Self.mimeType(forExtension: localURL.pathExtension.lowercased())
        entries[String(token)] = Entry(
            localURL: localURL,
            mimeType: mime,
            expiresAt: Date().addingTimeInterval(600)
        )
        guard let host = Self.primaryIPv4() else {
            throw NSError(domain: "Primuse.DLNA", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No LAN IPv4 to serve from"])
        }
        let encodedName = suggestedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "track"
        guard let url = URL(string: "http://\(host):\(boundPort)/\(token)/\(encodedName)") else {
            throw NSError(domain: "Primuse.DLNA", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build media URL"])
        }
        return url
    }

    private func pruneExpired() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }

    // MARK: Connection handling

    private func handleConnection(_ conn: NWConnection) {
        // 并发连接上限: 超过直接 cancel, 防 LAN 端无限累积 fd。
        guard activeConnections < Self.maxConnections else {
            conn.cancel(); return
        }
        activeConnections += 1
        // 半开连接 idle 超时: 凑齐请求头之前若超时未推进就 cancel; header 收齐后
        // 在 receiveRequest 里 cancel 掉 (后续 body/stream 可能很长不能限时)。
        let headerTimer = DispatchSource.makeTimerSource(queue: Self.networkQueue)
        headerTimer.schedule(deadline: .now() + Self.headerTimeout)
        headerTimer.setEventHandler { [weak conn] in
            plog("[DLNA] MediaServer connection header timeout, closing")
            conn?.cancel()
        }
        headerTimer.resume()
        // 连接终态统一在这里扣并发计数 + 停 timer, 无论是正常收尾、超时还是出错,
        // 都只走这一处, 避免在 routeRequest 的多个出口逐一处理漏算。
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                headerTimer.cancel()
                Task { @MainActor in
                    if let self, self.activeConnections > 0 { self.activeConnections -= 1 }
                }
            default:
                break
            }
        }
        conn.start(queue: Self.networkQueue)
        receiveRequest(on: conn, buffer: Data(), headerTimer: headerTimer)
    }

    private func receiveRequest(on conn: NWConnection, buffer: Data, headerTimer: DispatchSourceTimer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error {
                plog("[DLNA] MediaServer recv error: \(error.localizedDescription)")
                conn.cancel(); return
            }
            guard let data else {
                if isComplete { conn.cancel() }
                return
            }
            var next = buffer
            next.append(data)
            let marker = Data("\r\n\r\n".utf8)
            if let headerEnd = next.range(of: marker)?.upperBound {
                // header 收齐, idle timer 使命结束 (后续 body/stream 可能很长)。
                headerTimer.cancel()
                let header = next[..<headerEnd]
                let text = String(data: header, encoding: .utf8) ?? ""
                Task { @MainActor in self.routeRequest(text, on: conn) }
            } else if next.count > 64_000 {
                Task { @MainActor in self.respondStatus(400, on: conn) }
            } else {
                Task { @MainActor in self.receiveRequest(on: conn, buffer: next, headerTimer: headerTimer) }
            }
        }
    }

    private func routeRequest(_ raw: String, on conn: NWConnection) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { respondStatus(400, on: conn); return }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { respondStatus(400, on: conn); return }
        let method = String(parts[0])
        let path = String(parts[1])

        // path 形如 /<token>/<name.ext>, 取第一段当 token
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let segments = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard let token = segments.first, let entry = entries[token] else {
            respondStatus(404, on: conn); return
        }
        if entry.expiresAt <= Date() {
            entries.removeValue(forKey: token)
            respondStatus(410, on: conn); return
        }

        let rangeHeader = headerValue("range", in: raw)
        let isHEAD = method == "HEAD"
        let isGET = method == "GET"
        guard isHEAD || isGET else {
            respondStatus(405, on: conn); return
        }

        guard let size = (try? FileManager.default.attributesOfItem(atPath: entry.localURL.path))?[.size] as? Int else {
            respondStatus(404, on: conn); return
        }

        let (start, end): (Int, Int) = {
            if let rangeHeader, let r = parseByteRange(rangeHeader, totalSize: size) {
                return r
            }
            return (0, size - 1)
        }()
        if start >= size {
            respondStatus(416, on: conn, contentRange: "bytes */\(size)")
            return
        }

        let contentLength = end - start + 1
        let isPartial = rangeHeader != nil
        var headerLines: [String] = [
            isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK",
            "Content-Type: \(entry.mimeType)",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
            "Server: Primuse/1.0 (DLNA MediaServer)"
        ]
        if isPartial {
            headerLines.append("Content-Range: bytes \(start)-\(end)/\(size)")
        }
        // contentFeatures.dlna.org 提示是 audio + 支持 seek + streaming, 不少
        // renderer (Sony 系) 没这行就不播。
        headerLines.append("contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000")
        headerLines.append("transferMode.dlna.org: Streaming")
        let headerBlock = (headerLines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) ?? Data()

        if isHEAD {
            conn.send(content: headerBlock, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // GET: 先发 header, 再 chunked 推数据 (streamFile 是 nonisolated, 文件
        // IO 不回 main)。
        let fileURL = entry.localURL
        conn.send(content: headerBlock, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { conn.cancel(); return }
            Task { await self.streamFile(localURL: fileURL, start: start, end: end, on: conn) }
        })
    }

    /// 64KB 分块流, 不要一次性 load 整个文件 (FLAC 单首动辄 50MB 内存爆)。
    /// nonisolated: FileHandle 的 seek/read 是同步磁盘 IO, 一首 50MB FLAC 要
    /// 约 800 次 64KB 读取, 慢速存储 (iCloud 回迁) 单次读也可能阻塞数十毫秒,
    /// 绝不能跑在 MainActor 上拖卡 UI。读取放到 networkQueue, 读出 chunk 再 send。
    nonisolated private func streamFile(localURL: URL, start: Int, end: Int, on conn: NWConnection) async {
        do {
            let handle = try FileHandle(forReadingFrom: localURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            var remaining = end - start + 1
            let chunkSize = 65_536
            while remaining > 0 {
                let toRead = min(chunkSize, remaining)
                // 在 networkQueue 上做阻塞读, 不占 main。
                let data: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                    Self.networkQueue.async {
                        cont.resume(returning: try? handle.read(upToCount: toRead))
                    }
                }
                guard let data, !data.isEmpty else { break }
                remaining -= data.count
                let isLast = remaining == 0
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
                }
                if isLast { break }
            }
        } catch {
            plog("[DLNA] MediaServer streamFile error: \(error.localizedDescription)")
        }
        conn.cancel()
    }

    private func respondStatus(_ code: Int, on conn: NWConnection, contentRange: String? = nil) {
        let reason: String
        switch code {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 410: reason = "Gone"
        case 416: reason = "Range Not Satisfiable"
        default: reason = "OK"
        }
        var lines: [String] = [
            "HTTP/1.1 \(code) \(reason)",
            "Content-Length: 0",
            "Connection: close",
            "Server: Primuse/1.0 (DLNA MediaServer)"
        ]
        if let contentRange { lines.append("Content-Range: \(contentRange)") }
        let resp = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) ?? Data()
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// "Range: bytes=0-1024" / "bytes=500-" / "bytes=-200" 三种形式。
    private func parseByteRange(_ value: String, totalSize: Int) -> (Int, Int)? {
        guard totalSize > 0 else { return nil }
        let prefix = "bytes="
        guard let rangeStart = value.range(of: prefix) else { return nil }
        let after = value[rangeStart.upperBound...]
        let parts = after.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        if startStr.isEmpty {
            // "-200" → 最后 200 字节
            guard let suffix = Int(endStr), suffix > 0 else { return nil }
            let start = suffix >= totalSize ? 0 : totalSize - suffix
            return (start, totalSize - 1)
        }
        guard let start = Int(startStr), start >= 0, start < totalSize else { return nil }
        if endStr.isEmpty {
            return (start, totalSize - 1)
        }
        guard let end = Int(endStr), end >= start else { return nil }
        return (start, min(end, totalSize - 1))
    }

    private func headerValue(_ name: String, in raw: String) -> String? {
        let wanted = name.lowercased()
        return raw.split(separator: "\r\n").first { line in
            line.split(separator: ":", maxSplits: 1).first?.lowercased() == wanted
        }.flatMap { line in
            line.split(separator: ":", maxSplits: 1).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
        }
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "wma": return "audio/x-ms-wma"
        case "alac": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    /// 优先 en0 (Wi-Fi) IPv4。借鉴 DLNARendererService.primaryIPv4 实现。
    static func primaryIPv4() -> String? {
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
                                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if res == 0 {
                    candidates[name] = host.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return "" }
                        return String(cString: base)
                    }
                }
            }
            node = n.pointee.ifa_next
        }
        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.first
    }
}
