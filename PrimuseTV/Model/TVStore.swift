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

struct TVSource: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let host: String
    let status: TVSourceStatus
    let songs: Int
    let color: Color
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
        engine.onEnded = { [weak self] in self?.next() }
    }

    var hasRealLibrary: Bool { !library.visibleAlbums.isEmpty }

    /// 选中的歌(tvOS 暂无真实音频,仅展示真实元数据);未选中时不显示底部条/正在播放页。
    var nowPlaying: TVNowPlaying = .none
    var hasNowPlaying: Bool = false
    var lyrics: [TVLyricLine] = []        // tvOS 暂未同步歌词
    var queueUpNextIDs: [String] = []
    var playbackIssue: TVPlaybackIssue?   // 解析/播放受阻原因(展示用)
    var credentialBundle: CredentialBundle?   // 经 iCloud(CloudKit 加密)同步下来的源凭据
    private var queue: [String] = []      // 当前队列(真实 Song id)
    private var queueIndex = 0
    private var localLiked = Set<String>()

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
    var sources: [TVSource] { sourcesStore.sources.map { self.map($0) } }

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
        return TVAlbum(id: a.id, title: a.title, artist: a.artistName ?? "未知艺术家",
                       year: a.year ?? 0, tint: t1, tint2: t2, glyph: Self.glyph(a.title))
    }
    private func map(_ s: Song) -> TVSong {
        TVSong(id: s.id, albumID: s.albumID ?? "", title: s.title,
               artist: s.artistName ?? "未知艺术家", duration: s.duration,
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
                        host: s.host ?? s.basePath ?? s.type.displayName,
                        status: s.isEnabled ? .connected : .disabled, songs: cnt, color: c)
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

    /// 仅从本地磁盘重载(不联网),用于关闭自动同步时的启动。
    func reload() {
        library.reloadFromDisk()
        sourcesStore.reloadFromDisk()
        refreshVisibility()
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

    func next() {
        guard queueIndex + 1 < queue.count, let s = song(queue[queueIndex + 1]) else { return }
        queueIndex += 1
        startPlaying(s)
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
