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

/// 侧栏「工具」区的三个入口。点击不再切换路由 (不进详情栈), 而是以弹框
/// (`.sheet`) 形式覆盖在当前页上 —— 工具是临时操作面板, 用完即关, 不该
/// 占据主导航。`Identifiable` 让 `MacContentView` 能直接 `.sheet(item:)`。
enum MacTool: String, Identifiable, Hashable {
    case playlistImport
    case duplicates
    case scrobble

    var id: String { rawValue }
}

extension Notification.Name {
    static let primuseDetailOpenAlbum = Notification.Name("primuse.detail.openAlbum")
    static let primuseDetailOpenArtist = Notification.Name("primuse.detail.openArtist")
    static let primuseSelectScrobble = Notification.Name("primuse.route.scrobble")
    /// 跳到「歌单」总览 (删除当前歌单后用)。主容器同时会清掉详情栈, 避免栈里
    /// 还压着刚删掉那张歌单的空详情。
    static let primuseSelectPlaylists = Notification.Name("primuse.route.playlists")
}
#endif
