#if os(tvOS)
import SwiftUI
import Observation
import PrimuseKit

// MARK: - 轻量 view-model 类型
//
// UI 层数据契约。TVStore 现在由真实 MusicLibrary + SourcesStore 驱动(读取
// 同步下来的 library-cache.json / sources.json);快照为空时回退到样例数据,
// 这样全新安装、还没同步到曲库时 UI 仍可预览。Now Playing / 歌词 / 队列暂用
// 样例(tvOS 播放后续接入)。

struct TVAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let tint: Color
    let tint2: Color
    let glyph: String
}

struct TVSong: Identifiable, Hashable {
    let id: String
    let albumID: String
    let title: String
    let artist: String
    let duration: Double
    let format: String
    let bitrate: Int
    let sampleRate: Double
    let sourceID: String
    let plays: Int
    let liked: Bool
}

struct TVArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let tint: Color
    let tint2: Color
    let glyph: String
    let songCount: Int
}

enum TVPlaylistKind { case normal, smart, liked }

struct TVPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: TVPlaylistKind
    let count: Int
    let coverAlbumID: String
    static func == (l: TVPlaylist, r: TVPlaylist) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum TVSourceStatus { case connected, scanning, authFailed, disabled }

/// 该源能否在 Apple TV 上直接播放。
enum TVPlayability: Equatable {
    case ok                 // 有可用凭据(或 relay 端点),类型受支持
    case missingCredential  // 类型受支持但缺凭据(不在 bundle、无本地输入、无同步密码)
    case needsRelay         // SMB/SFTP/NFS/WebDAV 等需经 iPhone 中继,但中继端点未同步到
    case unsupported        // 类型在 TV 上无 resolver(如 macOS Apple Music 资料库)
}

struct TVSource: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let iconName: String   // 与手机端一致:MusicSourceType.iconName 的 SF Symbol
    let host: String
    let status: TVSourceStatus
    let songs: Int
    let color: Color
    let playability: TVPlayability   // 能否在 TV 播放(徽标用)
    let canEnterCredential: Bool     // 是否适合在 TV 上手动输入账号密码(服务端登录类源)
    static func == (l: TVSource, r: TVSource) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct TVSyllable: Hashable { let w: String; let d: Double }

struct TVLyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String
    let syllables: [TVSyllable]
    let translation: String
}

struct TVNowPlaying {
    var title: String
    var artist: String
    var album: String
    var albumID: String
    var tint: Color
    var tint2: Color
    var glyph: String
    var duration: Double
    var currentTime: Double
    var format: String
    var bitrate: Int
    var sampleRate: Double
    var sourcePath: String
}

// MARK: - Store

@MainActor
@Observable
final class TVStore {
    let library = MusicLibrary()
    let sourcesStore = SourcesStore()
    @ObservationIgnored let engine = TVAudioEngine()
    @ObservationIgnored private lazy var coordinator = TVPlaybackCoordinator(store: self, engine: engine)

    init() {
        engine.onEnded = { [weak self] in self?.advanceAfterEnd() }
    }

    var hasRealLibrary: Bool { !library.visibleAlbums.isEmpty }

    /// 选中的歌(tvOS 暂无真实音频,仅展示真实元数据);未选中时不显示底部条/正在播放页。
    var nowPlaying: TVNowPlaying = .none
    var hasNowPlaying: Bool = false
    var lyrics: [TVLyricLine] = []        // tvOS 暂未同步歌词
    var queueUpNextIDs: [String] = []
    var playbackIssue: TVPlaybackIssue?   // 解析/播放受阻原因(展示用)
    var credentialBundle: CredentialBundle?   // 经 iCloud(CloudKit 加密)同步下来的源凭据
    var sourcesRevision = 0   // 源启用/删除后 bump,强制 sources 视图重渲染(嵌套 store 观察传导不稳)
    private var queue: [String] = []      // 当前队列(真实 Song id)
    private var queueIndex = 0
    private var localLiked = Set<String>()

    // 播放模式(随机 / 循环)——供正在播放页传输键展示与切换。
    enum RepeatMode { case off, all, one }
    var shuffleEnabled = false
    var repeatMode: RepeatMode = .off
    var sleepTimerMinutes = 0   // 0 = 关闭
    @ObservationIgnored private var sleepWorkItem: DispatchWorkItem?

    /// 当前正在播放的真实 Song id(队列当前位)。
    var currentSongID: String? { queue.indices.contains(queueIndex) ? queue[queueIndex] : nil }

    /// 播放状态镜像自引擎(@Observable 组合,视图读取即订阅引擎变化)。
    var isPlaying: Bool { engine.isPlaying }
    var currentTime: Double { engine.currentTime }
    var duration: Double { engine.duration > 0 ? engine.duration : nowPlaying.duration }

    // MARK: 浏览数据(全部来自真实曲库;为空即显示空态)

    var albums: [TVAlbum] { library.visibleAlbums.map { self.map($0) } }
    var songs: [TVSong] { library.visibleSongs.map { self.map($0) } }
    var artists: [TVArtist] { library.visibleArtists.map { self.map($0) } }
    var playlists: [TVPlaylist] {
        let normal = library.playlists.map {
            mapPlaylist($0, kind: $0.id == MusicLibrary.likedSongsPlaylistID ? .liked : .normal)
        }
        let liked = normal.filter { $0.kind == .liked }
        let plain = normal.filter { $0.kind != .liked }
        let smart = library.smartPlaylists.map { self.mapSmart($0) }
        return liked + plain + smart
    }
    var sources: [TVSource] {
        _ = sourcesRevision   // 建立观察依赖:bump 即触发本视图刷新
        return sourcesStore.sources.map { self.map($0) }
    }

    // MARK: 查询

    func album(_ id: String) -> TVAlbum? { albums.first { $0.id == id } }
    func song(_ id: String) -> TVSong? { songs.first { $0.id == id } }
    func albumOf(_ song: TVSong) -> TVAlbum? { album(song.albumID) }
    func songs(forAlbum id: String) -> [TVSong] {
        library.songs(forAlbum: id).map { self.map($0) }
    }

    var recentlyPlayed: [TVSong] {
        library.recentlyPlayedSongs(limit: 12).map { self.map($0) }
    }
    var recentlyAddedAlbums: [TVAlbum] {
        library.recentlyAddedAlbums(limit: 12).map { self.map($0) }
    }
    var recommended: [TVAlbum] {
        let a = albums
        return a.count > 6 ? Array(a.suffix(6)) : a
    }

    func isLiked(_ id: String) -> Bool { localLiked.contains(id) }
    func toggleLiked(_ id: String) {
        if localLiked.contains(id) { localLiked.remove(id) } else { localLiked.insert(id) }
    }

    // MARK: 真实模型 → TV view-model 映射
    //
    // tvOS 暂未同步封面图(artwork 缓存在扫描设备本地),所以封面用「按 id 派生的
    // 渐变 + 首字」程序化绘制;标题/艺术家/年份等元数据都是真实的。

    private func map(_ a: Album) -> TVAlbum {
        let (t1, t2) = Self.tint(a.id.isEmpty ? a.title : a.id)
        return TVAlbum(id: a.id, title: a.title, artist: a.artistName ?? TVL("未知艺术家", "Unknown Artist"),
                       year: a.year ?? 0, tint: t1, tint2: t2, glyph: Self.glyph(a.title))
    }
    private func map(_ s: Song) -> TVSong {
        TVSong(id: s.id, albumID: s.albumID ?? "", title: s.title,
               artist: s.artistName ?? TVL("未知艺术家", "Unknown Artist"), duration: s.duration,
               format: s.fileFormat.displayName, bitrate: s.bitRate ?? 0,
               sampleRate: Double(s.sampleRate ?? 0) / 1000,
               sourceID: s.sourceID, plays: 0, liked: localLiked.contains(s.id))
    }
    private func map(_ a: Artist) -> TVArtist {
        let (t1, t2) = Self.tint(a.id.isEmpty ? a.name : a.id)
        return TVArtist(id: a.id, name: a.name, tint: t1, tint2: t2,
                        glyph: Self.glyph(a.name), songCount: a.songCount)
    }
    private func mapPlaylist(_ p: Playlist, kind: TVPlaylistKind) -> TVPlaylist {
        let s = library.songs(forPlaylist: p.id)
        return TVPlaylist(id: p.id, name: p.name, kind: kind,
                          count: s.count, coverAlbumID: s.first?.albumID ?? "")
    }
    private func mapSmart(_ sp: SmartPlaylist) -> TVPlaylist {
        TVPlaylist(id: sp.id, name: sp.name, kind: .smart, count: 0, coverAlbumID: "")
    }
    private func map(_ s: MusicSource) -> TVSource {
        let cnt = hasRealLibrary ? library.visibleSongs.filter { $0.sourceID == s.id }.count : s.songCount
        let (c, _) = Self.tint(s.id)
        return TVSource(id: s.id, name: s.name, type: s.type.rawValue,
                        iconName: s.type.iconName,
                        host: s.host ?? s.basePath ?? s.type.displayName,
                        status: s.isEnabled ? .connected : .disabled, songs: cnt, color: c,
                        playability: playability(for: s),
                        canEnterCredential: Self.manualCredentialTypes.contains(s.type))
    }

    // MARK: - TV 可播放性判断 + 手动凭据

    /// 用「服务端账号 + 密码」登录、且能在 TV 直连的源类型 —— 适合在 TV 上手动输入凭据。
    /// 云盘(OAuth)、relay 类(凭据在 iPhone 侧)、原生库源不在此列。
    private static let manualCredentialTypes: Set<MusicSourceType> = [
        .subsonic, .navidrome, .airsonic, .gonic,
        .synology, .qnap, .fnos, .ugreen,
        .jellyfin, .emby, .plex,
    ]

    /// 判断一个源能否在 Apple TV 上播放(注册表支持类型 + 凭据/中继可用性)。
    private func playability(for s: MusicSource) -> TVPlayability {
        let type = s.type
        // relay 类:能否播放取决于 iPhone 中继端点是否已同步过来。
        if RelayStreamResolver.relayTypes.contains(type) {
            return credentialBundle?.relay != nil ? .ok : .needsRelay
        }
        // 注册表里没有 resolver 的类型(如 macOS Apple Music 资料库)。
        if !StreamResolverRegistry.tvSupportedTypes.contains(type) {
            return .unsupported
        }
        return hasUsableCredential(for: s) ? .ok : .missingCredential
    }

    /// 是否有可用凭据:TV 本地输入 > 同步凭据包条目 > 同步 iCloud 钥匙串密码。
    private func hasUsableCredential(for s: MusicSource) -> Bool {
        if TVCredentialStore.hasLocalCredential(sourceID: s.id) { return true }
        if let e = credentialBundle?.entries[s.id], !e.isEmpty { return true }
        return TVCredentialStore.hasSyncedPassword(sourceID: s.id)
    }

    /// 当前用于预填输入框的用户名(本地输入 > bundle > 源自带 username)。
    func manualCredentialUsername(sourceID: String) -> String {
        if let local = TVCredentialStore.loadLocalCredential(sourceID: sourceID), !local.username.isEmpty {
            return local.username
        }
        if let u = credentialBundle?.entries[sourceID]?.username, !u.isEmpty { return u }
        return sourcesStore.source(id: sourceID)?.username ?? ""
    }

    /// 保存用户在 TV 上手动输入的账号密码(本地钥匙串),并失效旧会话、刷新徽标。
    func saveManualCredential(sourceID: String, username: String, password: String) {
        TVCredentialStore.saveLocalCredential(sourceID: sourceID, username: username, password: password)
        sourcesRevision += 1
        if let src = sourcesStore.source(id: sourceID) {
            Task { await StreamResolverRegistry.shared.invalidateSession(for: src) }
        }
    }

    /// 清除 TV 本地手动输入凭据(回退到同步凭据)。
    func clearManualCredential(sourceID: String) {
        TVCredentialStore.clearLocalCredential(sourceID: sourceID)
        sourcesRevision += 1
        if let src = sourcesStore.source(id: sourceID) {
            Task { await StreamResolverRegistry.shared.invalidateSession(for: src) }
        }
    }

    /// 「测试连接」:用当前凭据尝试解析该源的一首歌,返回给用户看的结果文案。
    func testConnection(forSourceID id: String) async -> String {
        guard let source = sourcesStore.source(id: id) else { return TVL("找不到该音乐源", "Source not found") }
        guard let song = library.songs.first(where: { $0.sourceID == id }) else {
            return TVL("该源在曲库中暂无歌曲,无法测试解析", "This source has no songs in the library to test")
        }
        let cred = TVCredentialStore.credential(for: source, bundle: credentialBundle)
        do {
            let resolved = try await StreamResolverRegistry.shared.resolve(for: song, source: source, credential: cred)
            return TVL("连接成功 · ", "Connected · ") + (resolved.url.host ?? TVL("已解析", "resolved"))
        } catch let e as StreamResolveError {
            switch e {
            case .unsupportedSourceType(let t):
                return TVL("类型「\(t.displayName)」在 Apple TV 上不支持播放",
                          "“\(t.displayName)” can’t be played directly on Apple TV")
            case .missingCredential:
                return TVL("缺少登录凭据 —— 请在此输入账号密码", "Missing credentials — enter your account and password here")
            case .authFailed:
                return TVL("鉴权失败 —— 账号或密码不正确", "Authentication failed — wrong account or password")
            case .badServerResponse(let code):
                return TVL("服务器返回 HTTP \(code)", "Server returned HTTP \(code)")
            case .cannotBuildURL:
                return TVL("无法构造播放地址", "Couldn’t build a playback URL")
            case .relayUnavailable:
                return TVL("需经 iPhone 中继 —— 请在手机上保持 Primuse 打开、与 TV 同一局域网",
                          "Needs iPhone relay — keep Primuse open on your phone, on the same Wi-Fi as the TV")
            }
        } catch {
            return TVL("连接失败 · ", "Connection failed · ") + error.localizedDescription
        }
    }

    /// 由字符串确定性派生封面渐变两端色。
    private static func tint(_ seed: String) -> (Color, Color) {
        var h: UInt64 = 5381
        for b in seed.utf8 { h = (h &* 33) &+ UInt64(b) }
        let hue = Double(h % 360) / 360.0
        return (Color(hue: hue, saturation: 0.45, brightness: 0.55),
                Color(hue: hue, saturation: 0.62, brightness: 0.22))
    }
    private static func glyph(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "♪" : String(t.prefix(1))
    }

    // MARK: 启动引导(从 iCloud 拉取快照并重载真实曲库)

    func bootstrap() async {
        #if DEBUG
        injectDebugCredential()   // 先注入,避免与自动播放钩子竞态(CloudKit await 期间)
        #endif
        await LibrarySnapshotSync.shared.download()
        reload()
        // 真实凭据(CloudKit)拉到才覆盖;模拟器无 iCloud 返回 nil 时保留上面注入的。
        if let creds = await LibrarySnapshotSync.shared.downloadCredentials() {
            credentialBundle = creds
        }
    }

    #if DEBUG
    /// 模拟器/截图测试:`TV_DEMO_CRED="sourceID:username:password"` 注入一条凭据,
    /// 绕过 CloudKit(模拟器无 iCloud 账号)直接演示真实流式播放。
    private func injectDebugCredential() {
        guard let raw = ProcessInfo.processInfo.environment["TV_DEMO_CRED"] else { return }
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        var bundle = credentialBundle ?? CredentialBundle()
        bundle.entries[parts[0]] = CredentialEntry(username: parts[1], password: parts[2])
        credentialBundle = bundle
    }
    #endif

    #if DEBUG
    /// 截图用:直接注入一条「正在播放」+ 演示歌词,不走真实播放(模拟器无可达源)。
    func loadDemoNowPlaying() {
        guard let album = albums.first else { return }
        let song = songs.first(where: { $0.albumID == album.id })
        nowPlaying = TVNowPlaying(
            title: song?.title ?? album.title,
            artist: album.artist,
            album: album.title,
            albumID: album.id,
            tint: album.tint, tint2: album.tint2, glyph: album.glyph,
            duration: song?.duration ?? 245,
            currentTime: 0,
            format: song?.format ?? "FLAC",
            bitrate: song?.bitrate ?? 1411,
            sampleRate: song?.sampleRate ?? 96,
            sourcePath: "")
        hasNowPlaying = true
        lyrics = Self.demoLyrics
    }

    static let demoLyrics: [TVLyricLine] = [
        .init(time: 0,  text: "灯光落在窗台上",      syllables: [], translation: "Light settles on the windowsill"),
        .init(time: 4,  text: "夜色把城市轻轻收起",   syllables: [], translation: "Night folds the city away"),
        .init(time: 9,  text: "我们沿着旧巷往回走",   syllables: [], translation: "We wander home down the old lane"),
        .init(time: 14, text: "把没说完的话留给风",   syllables: [], translation: "Leaving unfinished words to the wind"),
        .init(time: 19, text: "再亮一会儿吧 慢下来的光", syllables: [], translation: "Stay a little longer, slow light"),
        .init(time: 24, text: "让霓虹在水面上摇晃",   syllables: [], translation: "Let the neon sway on the water"),
        .init(time: 29, text: "每一步都踩在回声里",   syllables: [], translation: "Every step lands in an echo"),
        .init(time: 34, text: "带我回家 慢下来的光",  syllables: [], translation: "Slow light, take me home"),
    ]
    #endif

    /// 仅从本地磁盘重载(不联网),用于关闭自动同步时的启动。
    func reload() {
        library.reloadFromDisk()
        sourcesStore.reloadFromDisk()
        refreshVisibility()
        publishTopShelf()
        flushPendingDeepLink()
    }

    /// 生成 Top Shelf 展示数据(最近播放 + 资料库专辑),后台预取封面并写入 App Group,
    /// 供 Apple TV 主屏「顶部内容展示」扩展读取。没配 App Group 时发布器自身会跳过。
    func publishTopShelf() {
        let recent: [TopShelfPublisher.Draft] = recentlyPlayed.prefix(8).map { s in
            let alb = albumOf(s)
            return .init(id: s.id, title: s.title, subtitle: s.artist, artist: s.artist,
                         album: alb?.title ?? "", playURL: Self.topShelfLink(host: "play", key: "song", s.id))
        }
        let albumList = recentlyAddedAlbums.isEmpty ? albums : recentlyAddedAlbums
        let lib: [TopShelfPublisher.Draft] = albumList.prefix(12).map { a in
            .init(id: a.id, title: a.title, subtitle: a.artist, artist: a.artist,
                  album: a.title, playURL: Self.topShelfLink(host: "album", key: "id", a.id))
        }
        guard !recent.isEmpty || !lib.isEmpty else { return }
        Task.detached { await TopShelfPublisher.publish(recent: recent, albums: lib) }
    }

    private static func topShelfLink(host: String, key: String, _ value: String) -> String {
        var c = URLComponents()
        c.scheme = "primuse"; c.host = host
        c.queryItems = [URLQueryItem(name: key, value: value)]
        return c.url?.absoluteString ?? "primuse://\(host)"
    }

    // MARK: 深链(主屏 Top Shelf 点击 → 播放)

    /// 曲库未就绪时暂存的深链,reload/bootstrap 完成后再执行。
    @ObservationIgnored private var pendingDeepLink: URL?

    /// 处理 primuse:// 深链(主屏 Top Shelf 点击)。冷启动时曲库可能还没加载好,
    /// 先暂存,bootstrap/reload 完成后由 flushPendingDeepLink 执行。
    func handleDeepLink(_ url: URL) {
        pendingDeepLink = url
        flushPendingDeepLink()
    }

    func flushPendingDeepLink() {
        guard let url = pendingDeepLink, url.scheme == "primuse", hasRealLibrary else { return }
        pendingDeepLink = nil
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        switch url.host {
        case "play":
            if let id = q("song"), let s = song(id) { play(s) }
        case "album":
            if let id = q("id"), let a = album(id) { play(album: a) }
        default:
            break
        }
    }

    /// 隐藏「停用 / 已删除」音乐源的歌曲——资料库只显示有效源的内容。
    private func refreshVisibility() {
        let hidden = Set(sourcesStore.allSources.filter { $0.isDeleted || !$0.isEnabled }.map(\.id))
        library.updateDisabledSourceIDs(hidden)
    }

    /// 在 Apple TV 上删除音乐源:本地软删除 + 隐藏其歌曲 + 尽力把快照上传回 iCloud。
    /// 注意:手机才是源的权威方——若该源在手机上仍存在,下次同步可能回来,
    /// 彻底删除请在手机/电脑上操作。
    func deleteSource(_ id: String) {
        sourcesStore.remove(id: id)
        refreshVisibility()
        sourcesRevision += 1
        Task.detached { await LibrarySnapshotSync.shared.uploadNow() }
    }

    /// 在 Apple TV 上启用 / 停用音乐源。停用源的歌曲在资料库里是隐藏的,启用后即可
    /// 浏览 / 播放(快照含全量歌曲,显隐由各源的 enabled 状态决定)。
    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        sourcesStore.updateLocal(id) { $0.isEnabled = enabled }
        refreshVisibility()
        sourcesRevision += 1
        let fromThis = library.songs.filter { $0.sourceID == id }.count
        let visibleFromThis = library.visibleSongs.filter { $0.sourceID == id }.count
        plog("🔀 TV setSourceEnabled \(id)→\(enabled); 该源歌曲 全量=\(fromThis) 可见=\(visibleFromThis); 总可见=\(library.visibleSongs.count)")
        Task.detached { await LibrarySnapshotSync.shared.uploadNow() }
    }

    // MARK: 歌词

    /// 当前播放时间所在的歌词行索引。
    var currentLyricIndex: Int {
        var idx = 0
        for (i, l) in lyrics.enumerated() where l.time <= currentTime { idx = i }
        return idx
    }
    /// 当前行内逐字进度 0...1。
    var currentLyricProgress: Double {
        let i = currentLyricIndex
        guard i < lyrics.count else { return 0 }
        let start = lyrics[i].time
        let end = i + 1 < lyrics.count ? lyrics[i + 1].time : start + 3
        return max(0, min(1, (currentTime - start) / max(0.5, end - start)))
    }

    // MARK: 播放控制(AVPlayer 流式播放,真实流 URL 由 TVPlaybackCoordinator 解析)

    func togglePlayPause() { engine.togglePlayPause() }
    func seek(toFraction f: Double) { engine.seekToFraction(f) }
    func skipForward() { engine.skip(by: 10) }
    func skipBackward() { engine.skip(by: -10) }

    /// 选中一首歌播放:以其所属专辑为队列,从该曲开始。
    func play(_ song: TVSong) {
        setQueueAround(song)
        startPlaying(song)
    }

    func play(album: TVAlbum) {
        let albumSongs = songs(forAlbum: album.id)
        guard let first = albumSongs.first else { return }
        queue = albumSongs.map(\.id)
        queueIndex = 0
        startPlaying(first)
    }

    /// 全部播放 / 随机播放整个可见曲库(库多为散曲、没有真正专辑,所以播放范围用整库)。
    func playAll(shuffle: Bool) {
        var ids = library.visibleSongs.map(\.id)
        guard !ids.isEmpty else { return }
        if shuffle { ids.shuffle() }
        shuffleEnabled = shuffle
        queue = ids
        queueIndex = 0
        if let first = song(ids[0]) { startPlaying(first) }
    }

    func next() {
        // 手动下一首:忽略「单曲循环」;到队尾时「列表循环」则回到队首。
        if queueIndex + 1 < queue.count, let s = song(queue[queueIndex + 1]) {
            queueIndex += 1
            startPlaying(s)
        } else if repeatMode == .all, let first = queue.first, let s = song(first) {
            queueIndex = 0
            startPlaying(s)
        }
    }

    /// 一曲自然播完后的推进:单曲循环重播本曲,否则等同手动下一首。
    private func advanceAfterEnd() {
        plog("🎬 TV advanceAfterEnd: queueIndex=\(queueIndex)/\(queue.count) repeat=\(repeatMode)")
        if repeatMode == .one, queue.indices.contains(queueIndex), let s = song(queue[queueIndex]) {
            startPlaying(s)
        } else {
            next()
        }
    }

    /// 点击「下一首」队列里的某首,直接跳到它播放。
    func playQueueItem(at upNextIndex: Int) {
        let abs = queueIndex + 1 + upNextIndex
        guard queue.indices.contains(abs), let s = song(queue[abs]) else { return }
        queueIndex = abs
        startPlaying(s)
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        guard shuffleEnabled, queue.count > queueIndex + 1 else { refreshUpNext(); return }
        // 只打乱「当前曲之后」的部分,当前曲不动。
        var tail = Array(queue[(queueIndex + 1)...])
        tail.shuffle()
        queue = Array(queue[0...queueIndex]) + tail
        refreshUpNext()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
    }

    /// 睡眠定时:关→15→30→60→关 分钟。到点暂停播放。
    func cycleSleepTimer() {
        let presets = [0, 15, 30, 60]
        let cur = presets.firstIndex(of: sleepTimerMinutes) ?? 0
        sleepTimerMinutes = presets[(cur + 1) % presets.count]
        sleepWorkItem?.cancel()
        guard sleepTimerMinutes > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.engine.pause()
            self?.sleepTimerMinutes = 0
        }
        sleepWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(sleepTimerMinutes) * 60, execute: work)
    }

    private func refreshUpNext() {
        queueUpNextIDs = queueIndex + 1 < queue.count ? Array(queue[(queueIndex + 1)...]) : []
    }

    func previous() {
        // 播过 3 秒先回到开头,否则切上一首。
        if currentTime > 3 { engine.seek(to: 0); return }
        guard queueIndex - 1 >= 0, let s = song(queue[queueIndex - 1]) else { engine.seek(to: 0); return }
        queueIndex -= 1
        startPlaying(s)
    }

    private func setQueueAround(_ song: TVSong) {
        let albumSongs = songs(forAlbum: song.albumID)
        if albumSongs.count > 1, let idx = albumSongs.firstIndex(where: { $0.id == song.id }) {
            queue = albumSongs.map(\.id)
            queueIndex = idx
        } else if let idx = library.visibleSongs.firstIndex(where: { $0.id == song.id }) {
            // 无专辑 / 单曲专辑:用整个可见曲库续播,从这首开始,播完会自动播下一首。
            queue = library.visibleSongs.map(\.id)
            queueIndex = idx
        } else {
            queue = [song.id]
            queueIndex = 0
        }
    }

    /// 设置展示元数据 + 触发真实解析播放。
    private func startPlaying(_ song: TVSong) {
        let a = albumOf(song)
        nowPlaying = TVNowPlaying(
            title: song.title, artist: song.artist, album: a?.title ?? "",
            albumID: song.albumID, tint: a?.tint ?? TVColor.brand, tint2: a?.tint2 ?? .black,
            glyph: a?.glyph ?? "♪", duration: song.duration, currentTime: 0,
            format: song.format, bitrate: song.bitrate, sampleRate: song.sampleRate, sourcePath: "")
        hasNowPlaying = true
        lyrics = []
        queueUpNextIDs = queueIndex + 1 < queue.count ? Array(queue[(queueIndex + 1)...]) : []
        Task { await coordinator.play(songID: song.id) }
    }

    /// 协调器加载完歌词后回填(本地缓存 / 从源读 .lrc)。仅当仍是这首歌时生效。
    func applyLyrics(_ lines: [TVLyricLine], forSongID songID: String) {
        guard currentSongID == songID else { return }
        lyrics = lines
    }
}

extension TVNowPlaying {
    /// 占位「无正在播放」。
    static var none: TVNowPlaying {
        TVNowPlaying(title: "", artist: "", album: "", albumID: "",
                     tint: TVColor.brand, tint2: .black, glyph: "♪",
                     duration: 0, currentTime: 0, format: "", bitrate: 0,
                     sampleRate: 0, sourcePath: "")
    }
}
#endif
