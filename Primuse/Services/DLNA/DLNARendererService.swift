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
/// - **AVTransport 服务**: 实现 SetAVTransportURI / Play / Pause / Stop /
///   GetTransportInfo / GetPositionInfo 6 个 action; DIDL-Lite metadata 只
///   读 dc:title / upnp:artist (不读 cover, 因为推过来的 URL 一般是 HTTP
///   stream, 跟我们自己的 source 不同源, 解 ID3 太重)。
/// - **RenderingControl**: stub, 不支持音量调整 (用户在猿音 UI 自己调)。
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

    private var ssdpListener: NWListener?
    private var httpListener: NWListener?
    /// SSDP multicast 组,负责接收发到 239.255.255.250:1900 的 M-SEARCH
    /// (大多数控制点用 multicast search) 以及主动发 NOTIFY alive 广播。
    private var ssdpMulticast: NWConnectionGroup?
    /// NOTIFY alive 周期任务。`ssdp:byebye` 在 stop() 里同步发掉。
    private var notifyTask: Task<Void, Never>?
    /// 自分配的设备 UUID,持久化到 UserDefaults 让重启后控制点不会把我们当
    /// 成"新设备"重新订阅 (有些控制点会缓存 UUID)。
    private let deviceUUID: String

    /// 我们暴露的友好名称 ── 默认 "猿音 · <设备名>"。
    private let friendlyName: String

    /// 主 player 引用,SetAVTransportURI 时把 URL 推过去。
    private let player: AudioPlayerService

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
            isRunning = true
            statusText = String(localized: "dlna_status_listening")
            dlnaLog.notice("DLNA renderer started as \(self.friendlyName) (uuid=\(self.deviceUUID))")
        } catch {
            statusText = String(format: String(localized: "dlna_status_error_format"), error.localizedDescription)
            dlnaLog.error("DLNA start failed: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        // 优雅下线: 先发 byebye 让控制点立刻把我们从设备列表移除,再关 listener
        sendByebyeBatch()
        notifyTask?.cancel(); notifyTask = nil
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
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleSSDPConnection(conn) }
        }
        listener.start(queue: .main)
        ssdpListener = listener

        // Multicast group ── 监听 239.255.255.250:1900,接受 multicast
        // M-SEARCH (大多数控制点广播找设备),同时拿来发 NOTIFY alive。
        // Network.framework 的 NWConnectionGroup 是 iOS 14+ 标准 multicast
        // 入口,不需要自己撸 setsockopt。
        let multicast = try NWMulticastGroup(
            for: [.hostPort(host: Self.ssdpMulticastHost, port: Self.ssdpPort)]
        )
        let group = NWConnectionGroup(with: multicast, using: .udp)
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

    /// Multicast 收到 M-SEARCH 时单播回 200 OK。`NWConnectionGroup` 给的
    /// `message` 里能拿到 reply endpoint,直接走它回。
    private func handleMulticastDatagram(_ request: String, message: NWConnectionGroup.Message) {
        guard request.hasPrefix("M-SEARCH") else { return }
        let lower = request.lowercased()
        let interestedTargets = [
            "ssdp:all",
            "upnp:rootdevice",
            "urn:schemas-upnp-org:device:mediarenderer:1",
            "uuid:\(deviceUUID)",
        ]
        guard interestedTargets.contains(where: { lower.contains($0) }) else { return }
        // 把单播响应直接走 message.reply,不需要单独建 NWConnection。
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
            // 控制点会发 "M-SEARCH * HTTP/1.1 ... ST: urn:schemas-upnp-org:device:MediaRenderer:1"
            // 之类。命中 ST = ssdp:all / MediaRenderer:1 / 我们的 device type
            // 时,回一个 200 OK SSDP 响应。
            if request.contains("M-SEARCH") {
                let lower = request.lowercased()
                let interestedTargets = [
                    "ssdp:all",
                    "upnp:rootdevice",
                    "urn:schemas-upnp-org:device:mediarenderer:1",
                    "uuid:\(self.deviceUUID)",
                ]
                if interestedTargets.contains(where: { lower.contains($0) }) {
                    Task { await self.replySSDP(to: connection) }
                    return
                }
            }
            connection.cancel()
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
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleHTTPConnection(conn) }
        }
        listener.start(queue: .main)
        httpListener = listener
    }

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error {
                dlnaLog.debug("HTTP receive err: \(error.localizedDescription)")
                connection.cancel(); return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                if isComplete { connection.cancel() } else {
                    self.receiveHTTPRequest(on: connection)
                }
                return
            }
            Task { await self.routeHTTP(text, connection: connection) }
        }
    }

    private func routeHTTP(_ raw: String, connection: NWConnection) async {
        let lines = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { connection.cancel(); return }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/device.xml"):
            await sendXML(deviceDescriptionXML(), on: connection)
        case ("GET", "/AVTransport.xml"):
            await sendXML(avTransportSCPD, on: connection)
        case ("GET", "/RenderingControl.xml"):
            await sendXML(renderingControlSCPD, on: connection)
        case ("POST", "/control/AVTransport"):
            await handleAVTransportAction(raw: raw, connection: connection)
        default:
            await sendStatus(404, on: connection)
        }
    }

    private func handleAVTransportAction(raw: String, connection: NWConnection) async {
        // SOAPAction header 形如 `"urn:schemas-upnp-org:service:AVTransport:1#Play"`
        let soapActionLine = raw.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("soapaction:") }
            .map(String.init) ?? ""
        let action = soapActionLine.split(separator: "#").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r\n ")) ?? ""

        // SOAP body 在 \r\n\r\n 之后
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")

        switch action {
        case "SetAVTransportURI":
            // body 里 <CurrentURI>...</CurrentURI>; <CurrentURIMetaData>didl xml</...>
            let uri = extract(tag: "CurrentURI", from: body)
            let metadata = extract(tag: "CurrentURIMetaData", from: body)
            let title = extract(tag: "dc:title", from: metadata)
            let artist = extract(tag: "upnp:artist", from: metadata) ?? extract(tag: "dc:creator", from: metadata)
            if let uri, let url = URL(string: uri) {
                await playRemote(url: url, title: title ?? "Streaming", artist: artist)
                statusText = String(format: String(localized: "dlna_status_playing_format"), title ?? "Stream")
            }
            await sendSOAP(action: "SetAVTransportURI", body: "", on: connection)
        case "Play":
            player.togglePlayPause()
            await sendSOAP(action: "Play", body: "", on: connection)
        case "Pause":
            if player.isPlaying { player.togglePlayPause() }
            await sendSOAP(action: "Pause", body: "", on: connection)
        case "Stop":
            player.stop()
            statusText = String(localized: "dlna_status_listening")
            await sendSOAP(action: "Stop", body: "", on: connection)
        case "GetTransportInfo":
            let state = player.isPlaying ? "PLAYING" : "STOPPED"
            let body = """
            <CurrentTransportState>\(state)</CurrentTransportState>
            <CurrentTransportStatus>OK</CurrentTransportStatus>
            <CurrentSpeed>1</CurrentSpeed>
            """
            await sendSOAP(action: "GetTransportInfo", body: body, on: connection)
        case "GetPositionInfo":
            let cur = formatTime(player.currentTime)
            let dur = formatTime(player.duration)
            let body = """
            <Track>1</Track>
            <TrackDuration>\(dur)</TrackDuration>
            <RelTime>\(cur)</RelTime>
            <AbsTime>\(cur)</AbsTime>
            """
            await sendSOAP(action: "GetPositionInfo", body: body, on: connection)
        default:
            await sendSOAP(action: action, body: "", on: connection)
        }
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
            <friendlyName>\(friendlyName)</friendlyName>
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
            </serviceList>
          </device>
        </root>
        """
    }

    private var avTransportSCPD: String {
        // 最小 SCPD,声明 6 个我们实际响应的 action; 控制点会根据这个查 action
        // 是否存在。完整的 SCPD 有几十个 action / state variable,这里 trim 到
        // 真正能 dispatch 的那些。
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList>
            <action><name>SetAVTransportURI</name></action>
            <action><name>Play</name></action>
            <action><name>Pause</name></action>
            <action><name>Stop</name></action>
            <action><name>GetTransportInfo</name></action>
            <action><name>GetPositionInfo</name></action>
          </actionList>
        </scpd>
        """
    }

    private var renderingControlSCPD: String {
        // 空 SCPD ── 没实现任何 RenderingControl action, 但要返回个 stub 让
        // 控制点扫到这个服务时不报错。
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <actionList></actionList>
        </scpd>
        """
    }

    // MARK: - Networking helpers

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

    private func sendStatus(_ code: Int, on connection: NWConnection) async {
        let response = "HTTP/1.1 \(code) Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
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
                    candidates[name] = String(cString: host)
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
