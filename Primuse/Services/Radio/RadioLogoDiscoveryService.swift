import Foundation
import PrimuseKit

/// 发现流程的网络配置。放在类外面是必须的：抓取跑在后台执行器上，
/// 而 `@MainActor` 类型的静态成员同样带 MainActor 隔离，后台代码碰不到。
private enum RadioLogoDiscoveryTransport {
    /// 台标图片的下载上限。超过这个大小的多半不是台标，是台方放了一张海报。
    static let maximumLogoBytes = 3 * 1_024 * 1_024

    /// 主页 HTML 只读这么多 —— 图标声明都在 `<head>` 里。
    static let maximumHTMLPrefixBytes = 128 * 1_024

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

/// 给没有台标的电台自动找一张台标。
///
/// 三条线索，按可信度依次尝试：
/// 1. 连一次流，读 `icy-logo` 响应头和一块带内元数据(`StreamArtwork` / 图片型 `StreamUrl`)；
/// 2. 抓电台主页，取 og:image / apple-touch-icon / favicon；
/// 3. 拿流地址回查 radio-browser，取它记录的 favicon。
///
/// 三条规矩贯穿始终：
/// - **绝不挡路**。所有网络和解码都在后台执行器上跑，播放、添加、翻列表都不等它；
///   失败一律咽掉，界面顶多是继续显示占位图。
/// - **失败要退避**。一个台今天没有台标，明天多半也没有。连续失败按 5 分钟 →
///   30 分钟 → 2 小时 → 12 小时 → 3 天往后退，不反复骚扰台方服务器。
/// - **先验证再落库**。候选地址要真的下载得到、并且能解码成完整图片，才会写进电台 ——
///   否则存下的就是一个每次滚动列表都要重试一遍的坏地址。
@MainActor
@Observable
final class RadioLogoDiscoveryService {
    static let shared = RadioLogoDiscoveryService()

    /// 同时最多两个电台在发现中。台标是背景任务，不该和用户正在听的流抢带宽。
    private static let maximumConcurrentDiscoveries = 2

    /// 一批最多排这么多个。用户可能有几百个电台，一次全排进去只会让队列
    /// 空转很久 —— 剩下的下次进列表时自然会补上。
    private static let maximumBatchSize = 12

    private var states: [String: RadioLogoDiscoveryState] = [:]
    private var inFlight: Set<String> = []
    private var queue: [String] = []
    private var manualRequests: Set<String> = []
    private var statePersistTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var deletionObserver: NSObjectProtocol?
    private let stateURL: URL

    init(fileManager: FileManager = .default, stateURL: URL? = nil) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = stateURL ?? directory.appendingPathComponent("radio-logo-discovery.json")
        loadStates()
        observeDeletions()
    }

    deinit {
        if let deletionObserver {
            NotificationCenter.default.removeObserver(deletionObserver)
        }
    }

    /// 电台被删掉后清掉它的退避记录。不这么做的话，状态文件会随着「加了又删」
    /// 无限长大，而且同一个电台被重新添加时还会继承上一轮的退避。
    private func observeDeletions() {
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .primuseRadioStationDidDelete,
            object: nil,
            queue: .main
        ) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                RadioLogoDiscoveryService.shared.forget(stationIDs: [id])
            }
        }
    }

    // MARK: - 入口

    /// 批量排队。列表出现、添加完成、同步回来之后都可以调 —— 重复调用是安全的，
    /// 已经有台标的、正在发现的、还在退避期的都会被挡在门外。
    func discoverIfNeeded(for stations: [RadioStation]) {
        var enqueued = 0
        for station in stations where enqueued < Self.maximumBatchSize {
            if enqueue(station, manual: false) { enqueued += 1 }
        }
        pump()
    }

    /// 用户主动要求重新找一张。会绕过退避，但仍然不会覆盖用户自己选的图。
    func discoverNow(for station: RadioStation) {
        guard enqueue(station, manual: true) else { return }
        pump()
    }

    /// 电台被删除时清掉它的退避记录，免得状态文件无限长大。
    func forget(stationIDs: [String]) {
        guard !stationIDs.isEmpty else { return }
        var changed = false
        for id in stationIDs where states.removeValue(forKey: id) != nil {
            changed = true
        }
        queue.removeAll { stationIDs.contains($0) }
        if changed { schedulePersist() }
    }

    // MARK: - 队列

    private func enqueue(_ station: RadioStation, manual: Bool) -> Bool {
        // 服务器镜像台的封面由音乐源提供，不该由这里去猜。
        guard !station.isServerMirror, !station.isDeleted else { return false }
        guard !inFlight.contains(station.id), !queue.contains(station.id) else { return false }
        guard RadioLogoDiscoveryPolicy.shouldAttempt(
            state: states[station.id] ?? .initial,
            hasUserProvidedLogo: hasUserProvidedLogo(station),
            hasResolvedLogo: RadioLogoURLPolicy.normalized(station.remoteLogoURL) != nil,
            isManualRequest: manual
        ) else {
            return false
        }
        if manual { manualRequests.insert(station.id) }
        queue.append(station.id)
        return true
    }

    private func pump() {
        while inFlight.count < Self.maximumConcurrentDiscoveries, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let station = AppServices.shared.radioStationsStore.station(id: id) else {
                manualRequests.remove(id)
                continue
            }
            inFlight.insert(id)
            Task { [weak self] in
                await self?.run(station: station)
            }
        }
    }

    private func run(station: RadioStation) async {
        let manual = manualRequests.remove(station.id) != nil
        // 网络与解码都发生在这个 nonisolated 调用里，主线程不参与。
        let outcome = await Self.resolve(station: station)

        defer {
            inFlight.remove(station.id)
            pump()
        }

        guard let outcome else {
            states[station.id] = RadioLogoDiscoveryPolicy.failed(states[station.id] ?? .initial)
            schedulePersist()
            return
        }

        // 发现期间用户可能已经自己选了图，或者干脆把电台删了。
        guard let current = AppServices.shared.radioStationsStore.station(id: station.id),
              !hasUserProvidedLogo(current) else {
            states[station.id] = RadioLogoDiscoveryPolicy.succeeded(
                states[station.id] ?? .initial,
                source: outcome.source
            )
            schedulePersist()
            return
        }

        guard manual || RadioLogoDiscoveryPolicy.shouldApply(
            candidateSource: outcome.source,
            candidateURL: outcome.urlString,
            currentSource: current.remoteLogoSource,
            currentURL: current.remoteLogoURL
        ) else {
            states[station.id] = RadioLogoDiscoveryPolicy.succeeded(
                states[station.id] ?? .initial,
                source: outcome.source
            )
            schedulePersist()
            return
        }

        // 图片已经下载并验证过了，直接写进封面缓存 —— 界面随后拿到的是本地字节，
        // 不必再为同一张图跑一次网络。
        //
        // 缓存键用远程台标专属的那个，不能用电台的播放 songID：那个位置属于
        // 用户手选的台标，写进去就会把用户的图从磁盘上顶掉。
        await MetadataAssetStore.shared.cacheCover(
            outcome.imageData,
            forSongID: RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(
                for: current.id
            )
        )
        AppServices.shared.radioStationsStore.applyDiscoveredLogo(
            id: current.id,
            urlString: outcome.urlString,
            source: outcome.source,
            homepageURL: outcome.homepageURL
        )
        states[station.id] = RadioLogoDiscoveryPolicy.succeeded(
            states[station.id] ?? .initial,
            source: outcome.source
        )
        schedulePersist()
    }

    private func hasUserProvidedLogo(_ station: RadioStation) -> Bool {
        if let data = station.logoData, !data.isEmpty { return true }
        // 服务器镜像的 `logoFileName` 是音乐源给的封面引用，同样不该被顶掉。
        return station.logoFileName?.isEmpty == false
    }

    // MARK: - 发现本体(后台)

    private struct Outcome: Sendable {
        let urlString: String
        let source: RadioLogoSource
        let imageData: Data
        let homepageURL: String?
    }

    private nonisolated static func resolve(station: RadioStation) async -> Outcome? {
        let steps = RadioLogoDiscoveryPolicy.steps(
            streamURL: station.streamURL,
            knownHomepageURL: station.homepageURL,
            allowsDirectoryLookup: true
        )
        guard !steps.isEmpty else { return nil }

        // 流探测顺带能给出主页地址，后面的主页步骤要用上它。
        var discoveredHomepage: String?

        for step in steps {
            if Task.isCancelled { return nil }
            switch step {
            case .streamProbe:
                guard let url = station.url,
                      let probe = await RadioICYProbe.probe(url: url) else { continue }
                discoveredHomepage = probe.homepageURL
                if let candidate = probe.logoURL,
                   let data = await validatedImage(at: candidate) {
                    return Outcome(
                        urlString: candidate,
                        source: .icyHeader,
                        imageData: data,
                        homepageURL: probe.homepageURL
                    )
                }
                if let candidate = probe.inbandArtworkURL,
                   let data = await validatedImage(at: candidate) {
                    return Outcome(
                        urlString: candidate,
                        source: .inbandMetadata,
                        imageData: data,
                        homepageURL: probe.homepageURL
                    )
                }

            case .homepage(let homepage):
                if let outcome = await resolveHomepage(homepage) { return outcome }

            case .directoryLookup(let streamURL):
                guard let match = await RadioDirectoryClient.lookup(streamURL: streamURL) else {
                    continue
                }
                discoveredHomepage = discoveredHomepage ?? match.homepageURL
                if let candidate = match.faviconURL,
                   let data = await validatedImage(at: candidate) {
                    return Outcome(
                        urlString: candidate,
                        source: .directoryLookup,
                        imageData: data,
                        homepageURL: match.homepageURL
                    )
                }
                // 目录里没有 favicon，但给出了主页 —— 还值得再抓一次主页。
                if let homepage = match.homepageURL,
                   homepage != station.homepageURL,
                   let outcome = await resolveHomepage(homepage) {
                    return outcome
                }
            }
        }

        // 流探测报出来的主页没有在计划里(计划是发现前算的)，补一次。
        if let discoveredHomepage,
           discoveredHomepage != station.homepageURL,
           let outcome = await resolveHomepage(discoveredHomepage) {
            return outcome
        }
        return nil
    }

    /// 抓一次主页，按 og:image → apple-touch-icon → 磁贴图 → favicon 的顺序
    /// 逐个验证。最多试四个 —— 再往下就都是 16 像素的小图标了，不值得为它
    /// 多发请求。
    private nonisolated static func resolveHomepage(_ homepage: String) async -> Outcome? {
        guard let normalized = RadioLogoURLPolicy.normalized(homepage),
              let url = URL(string: normalized) else { return nil }

        var candidates: [String] = []
        if let html = await fetchHTMLPrefix(at: url) {
            candidates = RadioHomepageIconParser.icons(in: html, baseURL: url)
                .prefix(4)
                .map(\.urlString)
        }
        // 页面里一个图标都没声明(或者压根没抓到页面)时，还剩 `/favicon.ico`
        // 这条事实标准路径可以试。
        if let fallback = RadioHomepageIconParser.fallbackFaviconURL(for: url),
           !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        for candidate in candidates {
            if Task.isCancelled { return nil }
            guard let data = await validatedImage(at: candidate) else { continue }
            return Outcome(
                urlString: candidate,
                source: .homepageIcon,
                imageData: data,
                homepageURL: normalized
            )
        }
        return nil
    }

    /// 只读主页的前 128 KB。图标声明都在 `<head>` 里，整页可能有几 MB，
    /// 为一张台标把它全拉下来是不划算的。
    private nonisolated static func fetchHTMLPrefix(at url: URL) async -> String? {
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Primuse/Radio", forHTTPHeaderField: "User-Agent")
        guard let (fileURL, response) = try? await TrustedHTTPTransport.download(
            for: request,
            session: RadioLogoDiscoveryTransport.session,
            wholeResponsePrefixLimit: RadioLogoDiscoveryTransport.maximumHTMLPrefixBytes
        ) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }
        // 页面声明什么编码都不影响结论：图标地址是 ASCII，Latin-1 兜底足够
        // 把它原样取出来。
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 抓取

    /// 下载并验证一个台标候选。只有能解码成完整图片的才算数 ——
    /// 很多 favicon 地址早就 404 了，或者返回的是一页 HTML 错误提示。
    private nonisolated static func validatedImage(at urlString: String) async -> Data? {
        guard let normalized = RadioLogoURLPolicy.normalized(urlString),
              let url = URL(string: normalized) else { return nil }
        // 明文 HTTP 没被用户授权就不碰 —— 和流探测同样的边界。
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await TrustedHTTPTransport.data(
            for: request,
            session: RadioLogoDiscoveryTransport.session,
            maxBytes: RadioLogoDiscoveryTransport.maximumLogoBytes
        ) else {
            return nil
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        // Content-Type 只作参考：不少电台服务器把 PNG 标成 application/octet-stream。
        // 真正说了算的是能不能解码出一张完整的图。
        guard ArtworkImageCompatibility.isCompleteImage(data) else { return nil }
        return data
    }

    // MARK: - 退避状态持久化

    private func loadStates() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        states = (try? decoder.decode([String: RadioLogoDiscoveryState].self, from: data)) ?? [:]
    }

    /// 退避状态变化很密集(一批发现会连着写十几次)，攒一秒再落盘。
    private func schedulePersist() {
        statePersistTask?.cancel()
        statePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistStates()
        }
    }

    private func persistStates() {
        let snapshot = states
        let url = stateURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
