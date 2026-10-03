import Foundation
import PrimuseKit
import StoreKit

/// 播客用到的网络请求:取 feed、问 Apple 目录、取章节、探音频文件。
///
/// 明文 http 的公网地址和 App 里其他地方一样要用户逐个主机放行(`TrustedHTTPTransport`)。
/// 不少 http 的 feed 换成 https 也能取,所以先悄悄试一次 https,成功就记住 https 地址,
/// 实在只有 http 才把「要不要放行」交给界面去问。
enum PodcastNetwork {
    enum Failure: LocalizedError, Equatable {
        /// 只有明文 http,而用户还没放行这台主机。界面据此弹确认框。
        case insecureHTTP(host: String)
        case httpStatus(Int)
        case notAFeed
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .insecureHTTP(let host):
                return String(format: String(localized: "insecure_http_permission_required %@"), host)
            case .httpStatus(let code):
                return String(format: String(localized: "podcast_error_http %lld"), code)
            case .notAFeed:
                return String(localized: "podcast_error_not_a_feed")
            case .emptyResponse:
                return String(localized: "podcast_error_empty")
            }
        }
    }

    /// 有些 feed 托管方要求能认出来的 UA,通用的库 UA 会被拒;
    /// UA 里也别带网址 —— 小宇宙的防火墙见到带 `+https://…` 的 UA 直接回 403。
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Primuse/\(version) (Podcasts)"
    }()

    /// feed 和目录共用的会话。不走 URLCache:条件请求的 ETag 自己记,系统缓存反而会把 304 吞掉。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    /// feed 体积上限。最大的 feed(几千集带全文说明)也就二三十 MB。
    private static let feedByteLimit = 40 * 1024 * 1024

    // MARK: - Feeds

    enum FeedResult: Sendable {
        case notModified
        case fetched(Data, finalURL: URL, etag: String?, lastModified: String?)
    }

    static func fetchFeed(_ url: URL, etag: String? = nil, lastModified: String? = nil) async throws -> FeedResult {
        let target = try await reachableURL(for: url)
        var request = URLRequest(url: target)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await TrustedHTTPTransport.data(for: request, session: session, maxBytes: feedByteLimit)
        guard let http = response as? HTTPURLResponse else { throw Failure.emptyResponse }
        if http.statusCode == 304 { return .notModified }
        guard (200...299).contains(http.statusCode) else { throw Failure.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw Failure.emptyResponse }
        return .fetched(
            data,
            finalURL: target,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    /// 明文 http 的公网地址:先试 https,能连上就用它;不行再看用户有没有放行过这台主机。
    static func reachableURL(for url: URL) async throws -> URL {
        guard TrustedHTTPTransport.requiresPlainSocket(for: url) else { return url }
        if let upgraded = httpsVariant(of: url), await respondsOverHTTPS(upgraded) {
            return upgraded
        }
        if let target = TrustedHTTPTransport.trustTarget(for: url),
           SSLTrustStore.allowsInsecureHTTPHostSync(domain: target) {
            return url
        }
        throw Failure.insecureHTTP(host: TrustedHTTPTransport.trustTarget(for: url) ?? url.host ?? url.absoluteString)
    }

    static func httpsVariant(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http" else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }

    private static func respondsOverHTTPS(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return false }
        // 有的服务器不认 HEAD(405),但 https 通着就够了。
        return http.statusCode < 500
    }

    // MARK: - Directory and chapters

    static func json(from url: URL, maxBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await TrustedHTTPTransport.data(for: request, session: session, maxBytes: maxBytes)
        guard let http = response as? HTTPURLResponse else { throw Failure.emptyResponse }
        guard (200...299).contains(http.statusCode) else { throw Failure.httpStatus(http.statusCode) }
        return data
    }

    static func chapters(from url: URL) async -> [PodcastChapter] {
        guard let target = try? await reachableURL(for: url),
              let data = try? await json(from: target, maxBytes: 2 * 1024 * 1024) else { return [] }
        return PodcastChaptersJSON.decode(data, baseURL: target)
    }

    /// 单集文字稿(`podcast:transcript`)。逐词的 JSON 稿一小时也就几 MB。
    /// 只认带时间轴的 WebVTT / SRT / JSON;取不到或格式不认识返回 nil。
    static func transcript(from url: URL) async -> String? {
        guard let target = try? await reachableURL(for: url) else { return nil }
        var request = URLRequest(url: target)
        request.setValue("text/vtt, application/x-subrip, application/json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        guard let result = try? await TrustedHTTPTransport.data(for: request, session: session, maxBytes: 8 * 1024 * 1024),
              let http = result.1 as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return PodcastTranscriptDocument.subtitleText(from: result.0)
    }

    // MARK: - Enclosures

    /// 一个音频文件在起播那一刻的真实情况。
    struct EnclosureProbe: Sendable {
        /// 跳过统计/重定向之后的地址。之后的分段请求直接打这里,不再每段都经一次下载统计。
        var finalURL: URL
        var totalLength: Int64
        var supportsRange: Bool
        var probedAt: Date
    }

    /// 只要两个字节:看服务器认不认 Range、文件到底多大。很多节目的音频地址是动态插播广告的,
    /// feed 里写的长度和真实文件对不上,按它做分段请求会在半路读越界。
    static func probeEnclosure(_ url: URL) async -> EnclosureProbe? {
        guard let target = try? await reachableURL(for: url) else { return nil }
        var request = URLRequest(url: target)
        request.setValue(HTTPRangeProbePolicy.requestHeaderValue, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 8
        do {
            // 服务器不认 Range 时会把整个文件发过来:上限压小,超了就当「不支持分段」。
            let (data, response) = try await TrustedHTTPTransport.data(for: request, session: session, maxBytes: 64 * 1024)
            guard let http = response as? HTTPURLResponse else { return nil }
            let finalURL = http.url ?? target
            switch http.statusCode {
            case 206:
                guard let total = HTTPRangeProbePolicy.validatedTotalLength(
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: Int64(data.count)
                ) else {
                    return EnclosureProbe(finalURL: finalURL, totalLength: 0, supportsRange: false, probedAt: Date())
                }
                return EnclosureProbe(finalURL: finalURL, totalLength: total, supportsRange: true, probedAt: Date())
            case 200:
                return EnclosureProbe(finalURL: finalURL, totalLength: 0, supportsRange: false, probedAt: Date())
            default:
                plog("🎙️ Enclosure probe HTTP \(http.statusCode) host=\(target.host ?? "?")")
                return nil
            }
        } catch {
            plog("🎙️ Enclosure probe failed host=\(target.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }
}

/// 起播前探过的音频文件,按单集记半小时:重播、拖动、断流恢复都不用再探。
@MainActor
final class PodcastEnclosureProbeCache {
    static let shared = PodcastEnclosureProbeCache()
    private static let lifetime: TimeInterval = 30 * 60

    private var probes: [String: PodcastNetwork.EnclosureProbe] = [:]

    func probe(forEpisodeID id: String) -> PodcastNetwork.EnclosureProbe? {
        guard let probe = probes[id], Date().timeIntervalSince(probe.probedAt) < Self.lifetime else { return nil }
        return probe
    }

    func store(_ probe: PodcastNetwork.EnclosureProbe, forEpisodeID id: String) {
        probes[id] = probe
        if probes.count > 200 {
            let cutoff = Date().addingTimeInterval(-Self.lifetime)
            probes = probes.filter { $0.value.probedAt > cutoff }
        }
    }

    func invalidate(episodeID id: String) {
        probes.removeValue(forKey: id)
    }
}

/// 播客单集的文字稿:feed 里写了 `<podcast:transcript>` 才有。取到后按单集 id 写进歌词缓存,
/// 之后播放页、锁屏歌词都从缓存读,不再联网。同一集同时被几处要时只取一次。
@MainActor
enum PodcastTranscriptLoader {
    private static var inFlight: [String: Task<[LyricLine], Never>] = [:]

    static func lines(for song: Song) async -> [LyricLine] {
        guard PodcastPlaybackSong.isEpisode(song),
              let transcriptURL = PodcastStore.shared.episode(id: song.id)?.episode.transcriptURL else { return [] }
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            return cached
        }
        if let pending = inFlight[song.id] { return await pending.value }
        let songID = song.id
        let title = song.title
        let task = Task { @MainActor () -> [LyricLine] in
            defer { inFlight[songID] = nil }
            guard let text = await PodcastNetwork.transcript(from: transcriptURL) else {
                plog("🎙️ Transcript unavailable for '\(title)' host=\(transcriptURL.host ?? "?")")
                return []
            }
            let lines = LyricsContentParser.parse(text)
            guard !lines.isEmpty else { return [] }
            _ = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                lines,
                forSongID: songID,
                expectedFingerprint: nil,
                force: false
            )
            plog("🎙️ Transcript: \(lines.count) lines for '\(title)'")
            return lines
        }
        inFlight[songID] = task
        return await task.value
    }
}

/// Apple 播客目录:搜索、热门榜、按 id 查 feed 地址。地区码跟着 App Store 店面走。
@MainActor
@Observable
final class PodcastDirectoryService {
    static let shared = PodcastDirectoryService()

    @ObservationIgnored private var chartCache: [String: (shows: [PodcastDirectoryShow], fetchedAt: Date)] = [:]

    private var country: String { PodcastAvailabilityService.shared.policy.directoryCountry }

    func search(_ term: String) async throws -> [PodcastDirectoryShow] {
        guard let url = PodcastDirectory.searchURL(term: term, country: country, limit: 40) else { return [] }
        let data = try await PodcastNetwork.json(from: url)
        return try PodcastDirectory.decodeSearch(data)
    }

    func chart(genreID: Int?) async throws -> [PodcastDirectoryShow] {
        let key = "\(country)|\(genreID ?? 0)"
        if let cached = chartCache[key], Date().timeIntervalSince(cached.fetchedAt) < 3600 {
            return cached.shows
        }
        guard let url = PodcastDirectory.chartURL(country: country, genreID: genreID, limit: 50) else { return [] }
        let data = try await PodcastNetwork.json(from: url)
        let shows = try PodcastDirectory.decodeChart(data)
        chartCache[key] = (shows, Date())
        return shows
    }

    /// 榜单条目没有 feed 地址,订阅前按 id 查一次。
    func lookup(_ id: Int) async throws -> PodcastDirectoryShow? {
        guard let url = PodcastDirectory.lookupURL(ids: [id], country: country) else { return nil }
        let data = try await PodcastNetwork.json(from: url)
        return try PodcastDirectory.decodeSearch(data).first { $0.id == id }
    }
}

/// 按 App Store 店面决定播客能用到哪一步(见 `PodcastAvailabilityPolicy`)。
@MainActor
@Observable
final class PodcastAvailabilityService {
    static let shared = PodcastAvailabilityService()

    /// 店面取到之前按地区设置保守判断:判不出来时不放出手填地址。
    private(set) var policy: PodcastAvailabilityPolicy
    /// 已经按 App Store 店面判定过(而不是按手机地区猜的)。订阅的店面核对要等它。
    private(set) var isStorefrontResolved: Bool
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    private static let lastStorefrontKey = "primuse.podcast.lastStorefront"

    private init() {
        // StoreKit 要零点几秒到一秒才给店面;这段时间先按上次取到的店面判断,没取到过才按手机地区猜。
        // 不然手机地区是中国、账号在别的地区的设备每次启动都会先把订阅藏一下,冷启动的 Siri、CarPlay 恰好撞上。
        let cached = UserDefaults.standard.string(forKey: Self.lastStorefrontKey)
        policy = PodcastAvailabilityPolicy.resolve(
            storefrontCountryCode: Self.debugStorefrontOverride ?? cached,
            localeRegionCode: Locale.current.region?.identifier
        )
        isStorefrontResolved = Self.debugStorefrontOverride != nil
    }

    /// 允许手填 RSS 地址、导入 OPML。
    var allowsCustomFeeds: Bool { policy.allowsCustomFeeds }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { @MainActor [weak self] in
            if let storefront = await Storefront.current {
                self?.apply(countryCode: storefront.countryCode)
            }
            for await storefront in Storefront.updates {
                guard !Task.isCancelled else { return }
                self?.apply(countryCode: storefront.countryCode)
            }
        }
    }

    private func apply(countryCode: String) {
        let resolved = PodcastAvailabilityPolicy.resolve(
            storefrontCountryCode: Self.debugStorefrontOverride ?? countryCode,
            localeRegionCode: Locale.current.region?.identifier
        )
        let firstResolution = !isStorefrontResolved
        let changed = resolved != policy
        isStorefrontResolved = true
        UserDefaults.standard.set(countryCode, forKey: Self.lastStorefrontKey)
        if changed {
            policy = resolved
            plog("🎙️ Podcast availability: customFeeds=\(resolved.allowsCustomFeeds) directory=\(resolved.directoryCountry)")
        }
        // 订阅按新店面重新筛、重新核(第一次取到店面时也要:启动时是按手机地区猜的)。
        if changed || firstResolution {
            PodcastStore.shared.availabilityDidChange()
        }
    }

    /// 编译机上验两种店面用:`PRIMUSE_DEBUG_PODCAST_STOREFRONT=CHN` / `USA`。
    private static var debugStorefrontOverride: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PODCAST_STOREFRONT"]
        #else
        nil
        #endif
    }
}
