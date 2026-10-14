#if os(macOS)
import Foundation
import PrimuseKit

enum MacRoute: Hashable {
    case home
    case stats
    case search
    case sources
    case section(LibrarySection)
    /// 单独的"我喜欢的"快捷入口 — 等同于 .section(.songs) + isLiked 过滤。
    case liked
    /// 直接打开指定歌单 (从侧栏歌单列表点入)。
    case playlist(Playlist)
    /// 直接打开指定智能歌单 (从侧栏智能歌单列表点入)。
    case smartPlaylist(SmartPlaylist)
    case source(String)
}

extension MacRoute {
    var stableID: String {
        switch self {
        case .home: return "home"
        case .stats: return "stats"
        case .search: return "search"
        case .sources: return "sources"
        case .section(let section): return "section-\(section)"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .smartPlaylist(let smart): return "smartPlaylist-\(smart.id)"
        case .source(let id): return "source-\(id)"
        }
    }
}

/// 工具面板。标题栏的工具菜单和菜单栏「工具」里打开, 以弹框 (`.sheet`) 盖在当前页上 ——
/// 工具是临时操作面板, 用完即关, 不占侧栏。`Identifiable` 让 `MacContentView` 能直接
/// `.sheet(item:)`。
enum MacTool: String, Identifiable, Hashable, CaseIterable {
    case cacheSync
    case deviceTransfer
    case lyricsConverter
    case duplicates
    case scrobble

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cacheSync: CacheSyncLocalization.text("cache_sync_title")
        case .deviceTransfer: WiFiTransferText.string("nativeTitle")
        case .lyricsConverter: String(localized: "lyrics_converter_title")
        case .duplicates: String(localized: "Duplicate Song Cleanup")
        case .scrobble: String(localized: "Scrobble Configuration")
        }
    }

    var systemImage: String {
        switch self {
        case .cacheSync: "externaldrive.badge.wifi"
        case .deviceTransfer: "laptopcomputer.and.iphone"
        case .lyricsConverter: "arrow.left.arrow.right"
        case .duplicates: "arrow.triangle.2.circlepath"
        case .scrobble: "waveform.path.ecg"
        }
    }
}

#if DEBUG
/// 侧栏换页的耗时: 点下去 → 新页 `onAppear` → 主线程下一轮 → 内容真正摆出来。
/// 每段一行 🧪 日志, 编译机上用调试脚本的 `route:` 换页量出来。
@MainActor
enum MacRouteTiming {
    private static var start: ContinuousClock.Instant?
    private static var label = ""

    static func begin(_ route: MacRoute) {
        start = .now
        label = route.stableID
        PMWindowChromeTrace.start("route \(label)")
    }

    static func mark(_ event: String) {
        guard let start else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        plog("🧪 route \(label) \(event) +\(Int(ms.rounded()))ms")
    }

    /// 新页出现后再等主线程转一轮, 近似「这一帧摆完了」。
    static func markNextTurn(_ event: String) {
        Task { @MainActor in
            await Task.yield()
            mark(event)
        }
    }
}
#endif

extension Notification.Name {
    static let primuseDetailOpenAlbum = Notification.Name("primuse.detail.openAlbum")
    static let primuseDetailOpenArtist = Notification.Name("primuse.detail.openArtist")
    static let primuseSelectScrobble = Notification.Name("primuse.route.scrobble")
    /// 跳到「歌单」总览 (删除当前歌单后用)。主容器同时会清掉详情栈, 避免栈里
    /// 还压着刚删掉那张歌单的空详情。
    static let primuseSelectPlaylists = Notification.Name("primuse.route.playlists")
    /// 跳到侧栏的「电台」项。首页电台分区的「全部」用它 —— 侧栏本来就有这一项,
    /// push 一个带返回键的新页面等于同一个目的地有两条路径。
    static let primuseSelectRadio = Notification.Name("primuse.route.radio")
    /// 跳到侧栏的「有声」项。首页「在听的书」一栏的「全部」用它, 理由同上。
    /// object 是 `LibrarySection` 时跳到那一项(首页「播客更新」给 `.podcasts`)。
    static let primuseSelectSpokenWord = Notification.Name("primuse.route.spokenWord")
    /// 打开一本有声书的详情(object 是书的 id)。播放页「转到这本书」用它:
    /// 先切到侧栏的「有声」, 再把书压进那一栏的详情栈, 返回就回到书架。
    static let primuseDetailOpenSpokenWordBook = Notification.Name("primuse.detail.openSpokenWordBook")
    /// 菜单栏打开工具面板, object 是 `MacTool.rawValue`。
    static let primuseOpenMacTool = Notification.Name("primuse.mac.openTool")
    /// 菜单栏开关智能推荐面板。
    static let primuseToggleRecommendationsPanel = Notification.Name("primuse.mac.toggleRecommendations")
    /// 菜单栏打开听歌统计。
    static let primuseOpenListeningStats = Notification.Name("primuse.mac.openListeningStats")
}
#endif
