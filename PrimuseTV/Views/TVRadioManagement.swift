#if os(tvOS)
import SwiftUI
import UIKit
import ImageIO
import PrimuseKit

// MARK: - 台标

/// 取音乐源台标要用的源和凭据,由 `TVStore.radioLogoSourceContext(sourceID:)` 在主线程上
/// 解析好,再交给不在主线程上的加载器。只在内存里传,绝不写进 Top Shelf 的数据文件。
struct TVRadioLogoSourceContext: Sendable {
    let source: MusicSource
    let credential: SourceCredential
}

/// 电台台标的取法,顺序与 iPhone / Mac 同一份策略(`RadioStationArtworkResolutionPolicy`):
/// 用户自己选的图(`logoData`)→ 音乐源镜像台自带的封面引用(`logoFileName`,经音乐源连接器取)
/// → 目录、清单或自动发现带来的远程台标地址(电台已有自己的台标时只认用户自己填的链接)。
///
/// 三类磁盘缓存键互不覆盖:
/// - `radio:<id>`:用户台标(电台存储 `materializeLogos` 写的);
/// - `radio-remote:<id>#<地址摘要>`:公网台标;
/// - `radio:<id>#artwork-<fnv>`:音乐源台标(`RadioStationArtworkRemoteRequest.cacheDiscriminator`,
///   服务端换了封面引用就是新键,旧图不会一直显示下去)。
enum TVRadioLogoLoader {
    /// 台标来源的指纹。视图用它判断要不要重新取图;每次刷新都会算,所以只看决定取法的
    /// 那几个字段,用户台标只看字节数和末尾一小段,不把整份字节再哈希一遍。
    static func identity(for station: RadioStation) -> Int {
        var hasher = Hasher()
        hasher.combine(station.id)
        hasher.combine(station.logoData?.count)
        if let logo = station.logoData {
            // 换成字节数恰好相同的另一张图时也能认出来;图片文件的结尾各不相同。
            logo.suffix(32).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
        hasher.combine(station.logoFileName)
        hasher.combine(station.remoteLogoURL)
        hasher.combine(station.remoteLogoSource)
        hasher.combine(station.sourceID)
        hasher.combine(station.sourcePlaybackPath)
        hasher.combine(station.streamFormat)
        return hasher.finalize()
    }

    /// 按取图计划逐个候选尝试。`sourceContext` 在音乐源台标缓存没命中时才会被调用
    /// (它要读钥匙串);故意不给默认值,每个调用点都要明确交代音乐源从哪来。
    static func data(
        for station: RadioStation,
        sourceContext: @MainActor @Sendable (String) -> TVRadioLogoSourceContext?
    ) async -> Data? {
        let plan = RadioStationArtworkResolutionPolicy.makePlan(for: station)
        guard !plan.usesPlaceholderOnly else { return nil }
        let remoteLogoID = RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: station.id)
        let resolved: RadioStationArtworkResolution<Data>? = await RadioStationArtworkResolver.resolve(
            plan: plan
        ) { candidate in
            switch candidate {
            case .inline(let data):
                // 解不出来就往下走,交给后面的候选,不在这里停住。
                return UIImage(data: data) == nil ? nil : data
            case .cachedOrSource(let request) where request.songID == remoteLogoID:
                // 公网台标不带 sourceID,只有它会走公网请求。
                return await fetchRemoteLogo(cacheSongID: request.songID, address: request.coverReference)
            case .cachedOrSource(let request):
                return await sourceLogo(request, sourceContext: sourceContext)
            }
        }
        return resolved?.value
    }

    /// 写进电台之前先确认这个台标地址真的能取回一张图(`address` 须是
    /// `RadioLogoURLPolicy.normalized` 过的)。取回的图照常进缓存,台加上以后显示直接命中;
    /// 失败同样记进失败记录,之后不会每次显示都再请求一遍。
    static func probeRemoteLogo(_ address: String, forStationID stationID: String) async -> Bool {
        await fetchRemoteLogo(
            cacheSongID: RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: stationID),
            address: address
        ) != nil
    }

    /// 添加电台页搜索结果里的 favicon。与电台台标共用闸门、失败记录和磁盘缓存。
    static func directoryLogo(address: String) async -> Data? {
        await fetchRemoteLogo(cacheSongID: "radio-directory", address: address)
    }

    /// 在后台线程按显示尺寸解出缩略图,不常驻整张原图(台标常有上千像素,
    /// 资料库网格一屏几十张)。不会放大比 `maxPixelSize` 小的图。
    static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: 音乐源台标

    /// 音乐源镜像台的台标,经 `TVArtworkLoader.songCover` 的音乐源分支取:请求去重、
    /// 按引用和凭据身份记 5 分钟失败、按连接线路依次尝试,那边都已经有了。
    ///
    /// 不变量:没有受支持的音乐源就绝不能调用 `songCover`。它最后会把不认识的引用当成
    /// 公网地址直接请求,Jellyfin / Emby 的绝对地址就会被不带鉴权地打出去。
    private static func sourceLogo(
        _ request: RadioStationArtworkRemoteRequest,
        sourceContext: @MainActor @Sendable (String) -> TVRadioLogoSourceContext?
    ) async -> Data? {
        guard let sourceID = request.sourceID, !sourceID.isEmpty else { return nil }
        let key = request.cacheDiscriminator
        // 缓存命中不碰主线程、不读钥匙串:源离线、凭据还没到的时候以前取到的图照样显示。
        if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: key) {
            return cached
        }
        guard !Task.isCancelled,
              let context = await sourceContext(sourceID),
              context.source.id == sourceID,
              TVSourceAssetReader.supports(context.source.type) else { return nil }
        guard await fetchGate.acquire() else { return nil }
        // `songCover` 先按同一个键查缓存,等名额期间别处(卡片 / Top Shelf)已经取回的直接命中。
        var data: Data?
        if !Task.isCancelled {
            data = await TVArtworkLoader.shared.songCover(
                songID: key,
                coverRef: request.coverReference,
                source: context.source,
                credential: context.credential
            )
        }
        await fetchGate.release()
        return data
    }

    // MARK: 公网台标

    /// 远程台标唯一的取图入口:查缓存 → 失败记录 → 闸门 → 下载 → 校验(矢量图先栅格化)→ 写缓存。
    private static func fetchRemoteLogo(cacheSongID: String, address remote: String) async -> Data? {
        guard let url = URL(string: remote) else { return nil }
        // 地址进缓存键:别的设备换了台标地址,这里不会一直拿着旧图。
        let cacheID = cacheSongID + "#" + stableDigest(remote)
        if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: cacheID) {
            return cached
        }
        // 目录 favicon 大约四成是坏的;失败过的地址一段时间内不再请求,
        // 否则每次冷启动、每次 Top Shelf 发布都要把注定失败的请求再发一遍。
        guard await failureLog.allowsAttempt(for: remote) else { return nil }
        guard !Task.isCancelled else { return nil }

        // 首页电台那一排不是懒加载的,上千个台会同时要图;限住同时下载的数量。
        guard await fetchGate.acquire() else { return nil }
        let data = await downloadRemoteLogo(url, address: remote, cacheID: cacheID)
        await fetchGate.release()
        return data
    }

    /// 拿到下载名额以后的那一半。
    private static func downloadRemoteLogo(_ url: URL, address remote: String, cacheID: String) async -> Data? {
        // 等名额期间同一个地址可能已经被别处下好了,或者刚刚失败过。
        if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: cacheID) {
            return cached
        }
        guard !Task.isCancelled, await failureLog.allowsAttempt(for: remote) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                await record(.content, for: remote)
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                await record(FetchFailure(statusCode: http.statusCode), for: remote)
                return nil
            }
            guard http.expectedContentLength <= Int64(maximumBytes) else {
                await record(.content, for: remote)
                return nil
            }
            // 边下边数,超过上限立刻放弃,不把整份大文件拉进内存。
            var body = Data()
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard body.count < maximumBytes else {
                    await record(.content, for: remote)
                    return nil
                }
                body.append(byte)
            }
            data = body
        } catch {
            await record(Task.isCancelled ? .transient : FetchFailure(error: error), for: remote)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard !data.isEmpty, let usable = cacheableLogo(data) else {
            await record(.content, for: remote)
            return nil
        }
        await MetadataAssetStore.shared.cacheCover(usable, forSongID: cacheID)
        return usable
    }

    /// 与 `MetadataAssetStore.cacheCover` 同一道门槛,过不了它就进不了缓存,每次显示都得重新下载。
    /// 图本身能解出来、只是容器不规整的(结尾多了字节、缺结束标记等,网站 favicon 常见),
    /// 按上限尺寸重新编码成干净的 JPEG。`ArtworkImageCompatibility.staticFirstFrameJPEG`
    /// 在这里用不上:它自己先要求 `isCompleteImage`,正是这道门槛没过。
    ///
    /// 矢量台标(目录与清单里不少是 SVG)ImageIO 解不了,先按同一上限画成透明底 PNG
    /// 再过门槛:缓存里只放位图,卡片、Top Shelf 读缓存时都不用再认 SVG。
    private static func cacheableLogo(_ data: Data) -> Data? {
        if SVGImageSupport.looksLikeSVG(data) {
            guard let rasterized = SVGArtworkRasterizer.pngData(
                from: data,
                maximumPixelSize: cachedLogoPixelSize
            ), passesCacheGate(rasterized) else { return nil }
            return rasterized
        }
        if passesCacheGate(data) { return data }
        guard let image = thumbnail(from: data, maxPixelSize: cachedLogoPixelSize),
              let jpeg = image.jpegData(compressionQuality: 0.9),
              passesCacheGate(jpeg) else { return nil }
        return jpeg
    }

    private static func passesCacheGate(_ data: Data) -> Bool {
        ArtworkImageCompatibility.isCompleteImage(data)
            && !ArtworkImageCompatibility.hasRedundantJPEGSampling(data)
    }

    /// 失败分级:地址本身的问题(4xx、太大、不是图、矢量图画不出来)6 小时内不再试;服务端一时的问题
    /// (5xx、限流、超时、域名解析或连不上)5 分钟后再给机会;取消、断网、蜂窝限制不算这个地址的错。
    private enum FetchFailure {
        case content
        case service
        case transient

        var retryAfter: TimeInterval? {
            switch self {
            case .content: return 6 * 60 * 60
            case .service: return 5 * 60
            case .transient: return nil
            }
        }

        init(statusCode: Int) {
            switch statusCode {
            case 408, 429, 500...599: self = .service
            default: self = .content
            }
        }

        init(error: Error) {
            guard let urlError = error as? URLError else {
                self = error is CancellationError ? .transient : .content
                return
            }
            switch urlError.code {
            case .cancelled, .notConnectedToInternet, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                self = .transient
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                self = .service
            default:
                self = .content
            }
        }
    }

    private static func record(_ failure: FetchFailure, for address: String) async {
        guard let retryAfter = failure.retryAfter else { return }
        await failureLog.recordFailure(for: address, retryAfter: retryAfter)
    }

    private static let maximumBytes = 4 * 1_024 * 1_024
    /// 进缓存的台标长边上限:重新编码的位图与栅格化的矢量图都按它。Top Shelf 的台标画布
    /// 最大 1216,卡片按显示尺寸再缩略解码。
    private static let cachedLogoPixelSize = 1_024
    private static let fetchGate = TVRadioLogoFetchGate(limit: 4)
    private static let failureLog = TVRadioLogoFailureLog()
    /// 台标专用会话:请求与整体下载都有上限,一个慢站点不会拖住闸门名额;不带 Cookie,
    /// 也不沿用系统共享会话的磁盘缓存(取回的图已经进了台标缓存)。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 跨进程启动稳定的短摘要(`hashValue` 每次启动都会变,不能进磁盘缓存键)。
    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension RadioStation {
    /// 电视上显示的电台副标题。Kit 的 `playbackSubtitle` 没有格式和码率时回退成写死的
    /// 英文「LIVE」,那是 iPhone / Mac / CarPlay / 手表共用的,不动它;电视上换成本地化的文字。
    var tvPlaybackSubtitle: String {
        streamFormat != .automatic || (bitRate ?? 0) > 0
            ? playbackSubtitle
            : PMString("ext.tv.radio.live")
    }
}

/// 台标地址的失败记录。只在本进程内有效,不落盘:换个启动、换个网络就重新给机会。
private actor TVRadioLogoFailureLog {
    private var blockedUntil: [String: Date] = [:]

    func allowsAttempt(for address: String, now: Date = Date()) -> Bool {
        guard let until = blockedUntil[address] else { return true }
        if now < until { return false }
        blockedUntil[address] = nil
        return true
    }

    func recordFailure(for address: String, retryAfter: TimeInterval, now: Date = Date()) {
        blockedUntil[address] = now.addingTimeInterval(retryAfter)
    }
}

/// 同时取图的名额。等待中的任务被取消(卡片滑出屏幕、Top Shelf 重新发布)就立刻让出
/// 排队位置并返回 false,不会占着队列等到轮上才发现自己已经没用了。
private actor TVRadioLogoFetchGate {
    private let limit: Int
    private var active = 0
    private var nextToken = 0
    private var waiters: [(token: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// 拿到名额返回 true,调用方用完必须 `release()`;返回 false 表示没拿到,不用还。
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }
        let token = nextToken
        nextToken &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((token, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // 名额直接交给下一个等待者,active 不变。
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// 找不到说明它已经领到名额被唤醒了,那就由它自己用完再还。
    private func cancelWaiter(_ token: Int) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

// MARK: - 首页电台排末尾的卡片

/// 首页电台那一排末尾的功能卡片(「全部电台」「添加电台」),与电台卡片同尺寸。
struct TVRadioTileCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var dashed = true
    var width: CGFloat = 220
    /// 父视图的焦点绑定(见 `TVFocusButton`)。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    let action: () -> Void

    var body: some View {
        TVFocusButton(ring: false, action: action, focusBinding: focusBinding, focusID: focusID) { focused in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: TVRadius.cover, style: .continuous)
                        .fill(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
                    RoundedRectangle(cornerRadius: TVRadius.cover, style: .continuous)
                        .strokeBorder(
                            TVColor.cardBorder,
                            style: dashed
                                ? StrokeStyle(lineWidth: 2, dash: [10, 8])
                                : StrokeStyle(lineWidth: 2)
                        )
                    Image(systemName: icon)
                        .font(.system(size: width * 0.24, weight: .semibold))
                        .foregroundStyle(focused ? TVColor.brand : TVColor.textMuted)
                }
                .frame(width: width, height: width)
                .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(subtitle)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 12)
                .padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(subtitle))
    }
}

struct TVRadioAddCard: View {
    var width: CGFloat = 220
    /// 这一排删空以后,父视图把焦点交给这张卡片(`TVRadioFocusID.add`)。
    var focusBinding: FocusState<String?>.Binding? = nil
    let action: () -> Void

    var body: some View {
        TVRadioTileCard(
            icon: "plus",
            title: PMString("ext.tv.radio.add"),
            subtitle: PMString("ext.tv.radio.addSubtitle"),
            width: width,
            focusBinding: focusBinding,
            focusID: TVRadioFocusID.add,
            action: action
        )
    }
}

/// 首页只放前几个台;台多时末尾给一张卡片跳到资料库的「电台」。
struct TVRadioAllStationsCard: View {
    let count: Int
    var width: CGFloat = 220
    let action: () -> Void

    var body: some View {
        TVRadioTileCard(
            icon: "square.grid.2x2",
            title: PMString("ext.tv.radio.allStations"),
            subtitle: TVRadioText.stationCount(count),
            dashed: false,
            width: width,
            action: action
        )
    }
}

enum TVRadioText {
    /// 「N 个电台」。Kit 文案表没有复数规则,只有一个台时换成单数写法,英文不会出现「1 stations」。
    static func stationCount(_ count: Int) -> String {
        count == 1
            ? PMString("ext.tv.radio.stationCount.one")
            : PMString("ext.tv.radio.stationCount", count)
    }
}

// MARK: - 删除后的焦点

/// 电台卡片列表里的焦点 id:电台卡片用电台 id,「添加电台」入口用这个固定值
/// (电台 id 是 UUID 或 `as-` 开头的摘要,撞不上)。
enum TVRadioFocusID {
    static let add = "tv.radio.focus.add"
}

/// 删掉一张电台卡片后焦点该落到哪:原位置后面第一张还在的卡片,没有就前面最近的一张;
/// 都没有返回 nil,由调用方交给「添加电台」入口。
enum TVRadioDeleteFocusPolicy {
    static func target(
        afterRemoving removedID: String,
        from siblingIDs: [String],
        remaining: Set<String>
    ) -> String? {
        guard let index = siblingIDs.firstIndex(of: removedID) else { return nil }
        if let next = siblingIDs[(index + 1)...].first(where: { remaining.contains($0) }) {
            return next
        }
        return siblingIDs[..<index].last(where: { remaining.contains($0) })
    }
}

/// 等待确认删除的电台,连同弹出时这一排实际显示的顺序。
struct TVRadioDeleteRequest: Identifiable {
    let station: RadioStation
    let siblingIDs: [String]
    var id: String { station.id }
}

/// 首页电台排和资料库电台网格共用的删除确认弹层,挂在持有卡片列表的父视图上。
/// 确认删除后那张卡片已经不在了,系统没法把焦点还给它,只会退回顶栏;这里在弹层关闭后
/// 把焦点交给原位置的邻居。取消删除时卡片还在,焦点由系统照常还回去。
struct TVRadioDeleteConfirmationHost: ViewModifier {
    @Binding var request: TVRadioDeleteRequest?
    let focus: FocusState<String?>.Binding
    /// 关闭弹层时这一排实际显示的台,按显示顺序。
    let currentIDs: () -> [String]
    /// 按值传入:弹层内容不在卡片所在的视图树里渲染。
    let store: TVStore
    /// 弹层出现 / 关闭,只报给 TVRoot 登记,关闭后的焦点由这里负责。
    var onPresentationChanged: (Bool) -> Void = { _ in }

    /// 弹层关闭时 `request` 已经被清空,这里另留一份。
    @State private var presented: TVRadioDeleteRequest?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $request, onDismiss: restoreFocus) { request in
                TVRadioDeleteConfirmation(station: request.station)
                    .environment(store)
            }
            .onChange(of: request?.id) { _, id in
                if let request { presented = request }
                onPresentationChanged(id != nil)
            }
            .onDisappear {
                if request != nil { onPresentationChanged(false) }
            }
    }

    private func restoreFocus() {
        guard let presented else { return }
        self.presented = nil
        let current = currentIDs()
        // 取消了删除(或是不落盘的演示台):卡片还在,不用接手。
        guard !current.contains(presented.id) else { return }
        let target = TVRadioDeleteFocusPolicy.target(
            afterRemoving: presented.id,
            from: presented.siblingIDs,
            remaining: Set(current)
        ) ?? TVRadioFocusID.add
        Task { @MainActor in
            // 等弹层真正收起、列表换成删除后的样子再挪焦点。
            await Task.yield()
            focus.wrappedValue = target
        }
    }
}

// MARK: - 添加电台

/// 电视端添加电台。遥控器打字很费劲,所以主入口是按名称搜在线目录、一键添加;
/// 手动输入流地址作为第二个页签留着。添加的台写进与 iPhone / Mac 同一份电台存储。
struct TVRadioAddView: View {
    private enum Mode { case search, manual }
    private enum SearchState: Equatable {
        case idle
        case searching
        case finished
        case failed
    }
    private enum Field: Hashable { case query, name, url }

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .search
    @State private var query = ""
    @State private var results: [RadioDirectoryClient.Result] = []
    @State private var searchState: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var manualName = ""
    @State private var manualURL = ""
    @State private var manualError: String?
    @State private var notice: String?
    @State private var popular: [RadioDirectoryClient.Result] = []
    /// 热门电台所属地区的显示名;按全球取回时为 nil。
    @State private var popularRegionName: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .padding(.vertical, 50)
        }
        // 主入口是搜索,打开就把焦点放进查询框,不停在右上角的模式胶囊上。
        .onAppear { focusedField = mode == .search ? .query : .name }
        .onExitCommand { dismiss() }
        .onDisappear { searchTask?.cancel() }
        .task { await loadPopularStations() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(PMString("ext.tv.radio.add"))
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                Spacer(minLength: 0)
                modeButton(.search, title: PMString("ext.tv.radio.modeSearch"), icon: "magnifyingglass")
                modeButton(.manual, title: PMString("ext.tv.radio.modeManual"), icon: "link")
            }
            .focusSection()
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 24).padding(.bottom, 26)

            Group {
                switch mode {
                case .search: searchContent
                case .manual: manualContent
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: "icloud")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TVColor.textFaint)
                Text(notice ?? PMString("ext.tv.radio.syncHint"))
                    .tvFont(.caption)
                    .foregroundStyle(notice == nil ? TVColor.textFaint : TVColor.brand)
                    .lineLimit(2)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 60).padding(.vertical, 46)
        .frame(maxWidth: 1320, maxHeight: .infinity, alignment: .topLeading)
        .tvPanel(radius: 26)
    }

    private func modeButton(_ target: Mode, title: String, icon: String) -> some View {
        TVPillButton(
            title: title,
            systemImage: icon,
            style: mode == target ? .solid : .glass,
            isSelected: mode == target
        ) {
            let changed = mode != target
            mode = target
            notice = nil
            guard changed else { return }
            // 下面整块内容换掉了,焦点跟过去放进它的第一个输入框。等新内容出现再设。
            Task { @MainActor in
                await Task.yield()
                focusedField = target == .search ? .query : .name
            }
        }
    }

    // MARK: 搜索目录

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(PMString("ext.tv.radio.searchLabel"), icon: "magnifyingglass", active: focusedField == .query)
            HStack(spacing: 18) {
                TVTextFieldBox {
                    TextField("", text: $query)
                        .focused($focusedField, equals: .query)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .accessibilityLabel(Text(PMString("ext.tv.radio.searchLabel")))
                }
                TVPillButton(
                    title: PMString("ext.tv.radio.searchButton"),
                    systemImage: "magnifyingglass",
                    style: .solid,
                    action: search
                )
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .focusSection()

            searchResults
                .padding(.top, 22)
        }
        // 把查询删空就回到热门电台。在途的搜索一并取消,免得它晚些回来又把状态写成「已完成」。
        .onChange(of: query) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            searchTask?.cancel()
            searchTask = nil
            results = []
            searchState = .idle
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchState {
        case .idle where !popular.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    popularRegionName.map { PMString("ext.tv.radio.popularIn", $0) }
                        ?? PMString("ext.tv.radio.popular"),
                    systemImage: "flame"
                )
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(TVColor.textMuted)
                .padding(.horizontal, 8)
                resultList(popular)
            }
        case .idle:
            statusLine(PMString("ext.tv.radio.directoryNote"), icon: "globe")
        case .searching:
            HStack(spacing: 16) {
                ProgressView()
                Text(PMString("ext.tv.radio.searching"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, 10)
        case .failed:
            statusLine(PMString("ext.tv.radio.searchFailed"), icon: "exclamationmark.triangle", tint: TVColor.warn)
        case .finished where results.isEmpty:
            statusLine(PMString("ext.tv.radio.noResults"), icon: "radio")
        case .finished:
            resultList(results)
        }
    }

    private func resultList(_ items: [RadioDirectoryClient.Result]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { result in
                    resultRow(result)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .focusSection()
    }

    /// 还没输入时先摆出本地区(取不到就全球)投票最多的台,遥控器打字太费劲。
    /// 取不到就静默留在目录说明行。取到的结果在本次运行内留着(`TVRadioPopularCache`),
    /// 再打开这个面板不重新请求目录;失败不留,下次打开再试。
    private func loadPopularStations() async {
        guard popular.isEmpty else { return }
        let region = Locale.current.region?.identifier
        let code = region.flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0.uppercased() : nil }
        if let cached = TVRadioPopularCache.entry, cached.regionCode == code {
            popularRegionName = cached.regionName
            popular = cached.stations
            return
        }
        // 本地区请求出错(不是「本地区没有台」)时这次先用全球榜,但不留缓存,下次再试本地区。
        var regionalFailed = false
        if let code {
            do {
                let regional = try await RadioDirectoryClient.topStations(countryCode: code)
                guard !Task.isCancelled else { return }
                if !regional.isEmpty {
                    let name = Locale.current.localizedString(forRegionCode: code) ?? code
                    TVRadioPopularCache.entry = .init(regionCode: code, regionName: name, stations: regional)
                    popularRegionName = name
                    popular = regional
                    return
                }
            } catch {
                regionalFailed = true
            }
        }
        guard !Task.isCancelled,
              let global = try? await RadioDirectoryClient.topStations(countryCode: nil),
              !Task.isCancelled else { return }
        if !regionalFailed, !global.isEmpty {
            TVRadioPopularCache.entry = .init(regionCode: code, regionName: nil, stations: global)
        }
        popularRegionName = nil
        popular = global
    }

    private func resultRow(_ result: RadioDirectoryClient.Result) -> some View {
        let isAdded = store.hasRadioStation(streamURL: result.streamURL)
        return TVFocusButton(radius: 16, scale: 1.01, lift: 0, action: { add(result) }) { focused in
            HStack(spacing: 22) {
                TVRadioDirectoryLogo(urlString: result.faviconURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: result.name)
                        .tvFont(.rowTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    let detail = detailText(for: result)
                    Text(verbatim: detail.isEmpty ? " " : detail)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Label(
                    isAdded ? PMString("ext.tv.radio.added") : PMString("ext.tv.radio.addButton"),
                    systemImage: isAdded ? "checkmark.circle.fill" : "plus.circle"
                )
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(isAdded ? TVColor.brand : (focused ? TVColor.text : TVColor.textMuted))
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(Text(verbatim: result.name))
        .accessibilityValue(Text(isAdded ? PMString("ext.tv.radio.added") : detailText(for: result)))
    }

    private func detailText(for result: RadioDirectoryClient.Result) -> String {
        var parts: [String] = []
        if let country = result.country { parts.append(country) }
        if let codec = result.codec { parts.append(codec.uppercased()) }
        if let bitrate = result.bitrate { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " · ")
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searchState = .searching
        notice = nil
        searchTask = Task { @MainActor in
            do {
                let found = try await RadioDirectoryClient.search(name: text)
                guard !Task.isCancelled else { return }
                results = found
                searchState = .finished
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchState = .failed
            }
        }
    }

    private func add(_ result: RadioDirectoryClient.Result) {
        guard !store.hasRadioStation(streamURL: result.streamURL) else {
            notice = PMString("ext.tv.radio.duplicate")
            return
        }
        if let station = store.addRadioStation(
            name: result.name,
            streamURL: result.streamURL,
            homepageURL: result.homepageURL,
            logoURL: result.faviconURL,
            logoSource: .directoryFavicon
        ) {
            notice = PMString("ext.tv.radio.addedNotice", station.name)
        }
    }

    // MARK: 手动输入

    private var manualContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(PMString("ext.tv.radio.nameLabel"), icon: "textformat", active: focusedField == .name)
            TVTextFieldBox {
                TextField("", text: $manualName)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .url }
                    .accessibilityLabel(Text(PMString("ext.tv.radio.nameLabel")))
            }
            fieldLabel(PMString("ext.tv.radio.urlLabel"), icon: "link", active: focusedField == .url)
                .padding(.top, 24)
            TVTextFieldBox(mono: true) {
                TextField("", text: $manualURL)
                    .focused($focusedField, equals: .url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addManual)
                    .accessibilityLabel(Text(PMString("ext.tv.radio.urlLabel")))
            }

            HStack(spacing: 18) {
                TVPillButton(
                    title: PMString("ext.tv.radio.addButton"),
                    systemImage: "plus",
                    style: .solid,
                    action: addManual
                )
                if let manualError {
                    Label(manualError, systemImage: "exclamationmark.triangle")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.warn)
                        .lineLimit(2)
                }
            }
            .padding(.top, 30)
        }
        .onChange(of: manualName) { _, _ in manualError = nil }
        .onChange(of: manualURL) { _, _ in manualError = nil }
    }

    private func addManual() {
        let name = RadioStationValidation.normalizedName(manualName)
        guard let url = RadioStationValidation.normalizedURLString(manualURL), !name.isEmpty else {
            manualError = PMString("ext.tv.radio.invalidInput")
            return
        }
        guard !store.hasRadioStation(streamURL: url) else {
            manualError = PMString("ext.tv.radio.duplicate")
            return
        }
        guard let station = store.addRadioStation(name: name, streamURL: url) else {
            manualError = PMString("ext.tv.radio.invalidInput")
            return
        }
        manualName = ""
        manualURL = ""
        manualError = nil
        notice = PMString("ext.tv.radio.addedNotice", station.name)
    }

    // MARK: 零件

    private func fieldLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? TVColor.brand : TVColor.textFaint)
                .frame(width: 26)
            Text(title)
                .tvFont(.caption)
                .foregroundStyle(active ? TVColor.text : TVColor.textFaint)
        }
        .padding(.bottom, 10)
    }

    private func statusLine(_ text: String, icon: String, tint: Color = TVColor.textMuted) -> some View {
        Label(text, systemImage: icon)
            .tvFont(.caption)
            .foregroundStyle(tint)
            .padding(.top, 10)
    }
}

/// 添加电台面板的热门电台,本次运行内只取一次。面板每次打开都是新视图,
/// 不留一份的话每开一次都要再请求一两次目录。按地区码对应,系统地区改了就重新取。
@MainActor
private enum TVRadioPopularCache {
    struct Entry {
        let regionCode: String?
        /// 地区的显示名;按全球取回时为 nil。
        let regionName: String?
        let stations: [RadioDirectoryClient.Result]
    }

    static var entry: Entry?
}

/// 搜索结果里的台标缩略图。目录给的 favicon 常常失效,取不到就显示电台图标。
/// 走台标加载器(闸门、失败记录、磁盘缓存),解出的缩略图在本次运行内留一份,
/// 来回切换热门和搜索结果时不再重新解码。
private struct TVRadioDirectoryLogo: View {
    let urlString: String?
    private let side: CGFloat = 72
    @State private var image: UIImage?

    @MainActor private static let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    private var address: String? { RadioLogoURLPolicy.normalized(urlString) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TVColor.surface)
            Image(systemName: "radio.fill")
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(TVColor.textGhost)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: address) {
            guard let address else {
                image = nil
                return
            }
            let key = address as NSString
            if let cached = Self.thumbnails.object(forKey: key) {
                image = cached
                return
            }
            image = nil
            guard let data = await TVRadioLogoLoader.directoryLogo(address: address),
                  !Task.isCancelled else { return }
            let pixelSize = Int(side * 2)
            let decoded = await Task.detached(priority: .utility) {
                TVRadioLogoLoader.thumbnail(from: data, maxPixelSize: pixelSize)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            Self.thumbnails.setObject(decoded, forKey: key)
            image = decoded
        }
    }
}

// MARK: - 删除确认

/// 删除电台前确认。电台存储与 iPhone / Mac 共用,开着 iCloud 同步时删除会传到
/// 所有设备,所以不做「长按即删」。
struct TVRadioDeleteConfirmation: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let station: RadioStation

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    TVRadioArtworkView(station: station, size: 120, radius: 18, store: store)
                    Text(PMString("ext.tv.radio.deleteConfirm", station.name))
                        .tvFont(.sectionTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                }
                Text(PMString("ext.tv.radio.deleteNote"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: PMString("ext.tv.radio.delete"),
                        systemImage: "trash",
                        style: .solid
                    ) {
                        store.removeRadioStation(id: station.id)
                        dismiss()
                    }
                    TVPillButton(title: PMString("ext.tv.sources.cancel"), systemImage: "xmark") {
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .tvPanel(radius: 22)
        }
        .onExitCommand { dismiss() }
    }
}
// MARK: - 重命名

/// 电台重命名。不这样的话用户只能删了重加,而删除会同步到所有设备。
/// 订阅来的台名字归清单管,不走这里。
struct TVRadioRenameView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let station: RadioStation
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(station: RadioStation) {
        self.station = station
        _name = State(initialValue: station.name)
    }

    private var normalizedName: String { RadioStationValidation.normalizedName(name) }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    TVRadioArtworkView(station: station, size: 120, radius: 18, store: store)
                    Text(PMString("ext.tv.radio.renameTitle"))
                        .tvFont(.sectionTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(PMString("ext.tv.radio.nameLabel"))
                        .tvFont(.caption)
                        .foregroundStyle(fieldFocused ? TVColor.text : TVColor.textFaint)
                    TVTextFieldBox {
                        TextField("", text: $name)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityLabel(Text(PMString("ext.tv.radio.nameLabel")))
                    }
                }
                HStack(spacing: 18) {
                    TVPillButton(
                        title: PMString("ext.tv.sources.form.save"),
                        systemImage: "checkmark",
                        style: .solid,
                        action: save
                    )
                    .disabled(normalizedName.isEmpty)
                    TVPillButton(title: PMString("ext.tv.sources.cancel"), systemImage: "xmark") {
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .tvPanel(radius: 22)
        }
        .onExitCommand { dismiss() }
    }

    private func save() {
        guard !normalizedName.isEmpty else { return }
        if normalizedName != station.name {
            store.renameRadioStation(id: station.id, to: normalizedName)
        }
        dismiss()
    }
}

// MARK: - 「电台」一级页

/// tvOS「电台」一级页:与音乐、有声并列的收听空间。页面主体就是按文件夹筛选的
/// 全部电台网格(原来资料库里的「电台」筛选),首页那排「全部电台」也跳到这里。
struct TVRadioPageView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    private let cols = 4
    private let gap: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let contentW = geo.size.width - TVSpace.pageH * 2 - 28
            let cell = max(140, (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols))
            let columns = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(PMString("ext.tv.radio.title"))
                            .tvFont(.pageTitle)
                            .foregroundStyle(TVColor.text)
                        if !store.radioStations.isEmpty {
                            Text(TVRadioText.stationCount(store.radioStations.count))
                                .tvFont(.caption)
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
                    TVRadioLibrarySection(
                        columns: columns,
                        cell: cell,
                        spacing: gap,
                        openPlayer: openPlayer,
                        onModalActivityChanged: onModalActivityChanged,
                        onModalPresentationChanged: onModalPresentationChanged
                    )
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, TVSpace.pageBottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageTop)
        }
        .background(TVColor.bg)
        .accessibilityIdentifier("tv.radio.page")
    }
}

// MARK: - 资料库「电台」

/// 资料库里的全部电台:按文件夹筛选的网格。首页那一排只放前几个台,台多的时候
/// (音乐源镜像动辄上千个)来这里看全部 —— 网格是懒加载的。
/// 文件夹只能在 iPhone / Mac 上整理,这里只读。
struct TVRadioLibrarySection: View {
    @Environment(TVStore.self) private var store
    let columns: [GridItem]
    let cell: CGFloat
    let spacing: CGFloat
    var openPlayer: () -> Void = {}
    /// 「添加电台」弹层:关闭后由 TVRoot 把焦点放回资料库的筛选行。
    var onModalActivityChanged: (Bool) -> Void = { _ in }
    /// 卡片的重命名 / 删除确认:只报弹层在不在,关闭后的焦点由这里和系统负责
    /// (重命名回到原卡片,删除交给邻居),TVRoot 不改焦点。
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    private enum Selection: Hashable {
        case all
        case folder(String)   // 文件夹名的比较键
        case ungrouped
    }

    @State private var selection: Selection = .all
    @State private var showsAdd = false
    @State private var deleteRequest: TVRadioDeleteRequest?
    @FocusState private var focusedRadioID: String?

    /// 选中的文件夹被别的设备删掉或改名时回到「全部」。
    private var effectiveSelection: Selection {
        switch selection {
        case .all:
            return .all
        case .folder(let key):
            return store.radioStationsByFolderKey[key]?.isEmpty == false ? selection : .all
        case .ungrouped:
            return store.radioUngroupedCount > 0 ? .ungrouped : .all
        }
    }

    private var stations: [RadioStation] {
        switch effectiveSelection {
        case .all: return store.radioStations
        case .folder(let key): return store.radioStationsByFolderKey[key] ?? []
        case .ungrouped: return store.radioStationsByFolderKey[""] ?? []
        }
    }

    var body: some View {
        Group {
            if store.radioStations.isEmpty {
                TVEmptyState(
                    icon: "radio",
                    title: PMString("ext.tv.radio.empty"),
                    subtitle: PMString("ext.tv.radio.syncHint"),
                    actionTitle: PMString("ext.tv.radio.add"),
                    // 电台全删空后筛选行也没了,删除后的焦点交给这颗按钮。
                    focusBinding: $focusedRadioID,
                    focusID: TVRadioFocusID.add,
                    action: { showsAdd = true }
                )
                .frame(minHeight: 520)
            } else {
                let shown = stations
                // 按文件夹筛选时,长按挪动只在这个文件夹里的台之间算。
                let shownIDs = shown.map(\.id)
                VStack(alignment: .leading, spacing: 26) {
                    chips
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(shown) { station in
                            TVRadioStationCard(
                                station: station,
                                width: cell,
                                siblingIDs: shownIDs,
                                focusBinding: $focusedRadioID,
                                onDelete: { deleteRequest = TVRadioDeleteRequest(station: $0, siblingIDs: shownIDs) },
                                onModalPresentationChanged: onModalPresentationChanged,
                                action: openPlayer
                            )
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showsAdd) {
            TVRadioAddView().environment(store)
        }
        .onChange(of: showsAdd) { _, shows in onModalActivityChanged(shows) }
        .onDisappear {
            if showsAdd { onModalActivityChanged(false) }
        }
        // 这个文件夹删空时网格会回到「全部」,焦点交给筛选行的「添加」胶囊;
        // 电台全删空时交给空态上的「添加电台」按钮。
        .modifier(TVRadioDeleteConfirmationHost(
            request: $deleteRequest,
            focus: $focusedRadioID,
            currentIDs: { stations.map(\.id) },
            store: store,
            onPresentationChanged: onModalPresentationChanged
        ))
    }

    private var chips: some View {
        let current = effectiveSelection
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                chip(
                    PMString("ext.tv.library.filter.all") + " · \(store.radioStations.count)",
                    icon: "radio",
                    target: .all,
                    current: current
                )
                ForEach(store.radioFolders) { folder in
                    chip(
                        "\(folder.name) · \(folder.stationCount)",
                        icon: "folder",
                        target: .folder(RadioStationOrganization.comparisonKey(folder.name)),
                        current: current
                    )
                }
                if store.radioUngroupedCount > 0, !store.radioFolders.isEmpty {
                    chip(
                        PMString("ext.tv.radio.ungrouped") + " · \(store.radioUngroupedCount)",
                        icon: "tray",
                        target: .ungrouped,
                        current: current
                    )
                }
                TVPillButton(
                    title: PMString("ext.tv.radio.add"),
                    systemImage: "plus",
                    focusBinding: $focusedRadioID,
                    focusID: TVRadioFocusID.add
                ) {
                    showsAdd = true
                }
                .padding(.leading, 18)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .focusSection()
    }

    private func chip(_ title: String, icon: String, target: Selection, current: Selection) -> some View {
        TVPillButton(
            title: title,
            systemImage: icon,
            style: current == target ? .solid : .glass,
            isSelected: current == target
        ) {
            selection = target
        }
    }
}
#endif
