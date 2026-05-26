#if os(macOS)
import Foundation
import PrimuseKit

enum MacRoute: Hashable {
    case home
    case stats
    case search
    case sources
    case playlistImport
    case duplicates
    case scrobble
    case section(LibrarySection)
    /// 单独的"我喜欢的"快捷入口 — 等同于 .section(.songs) + isLiked 过滤。
    case liked
    /// 直接打开指定歌单 (从侧栏歌单列表点入)。
    case playlist(Playlist)
    case source(String)
}

extension MacRoute {
    var stableID: String {
        switch self {
        case .home: return "home"
        case .stats: return "stats"
        case .search: return "search"
        case .sources: return "sources"
        case .playlistImport: return "playlistImport"
        case .duplicates: return "duplicates"
        case .scrobble: return "scrobble"
        case .section(let section): return "section-\(section)"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .source(let id): return "source-\(id)"
        }
    }
}

extension Notification.Name {
    static let primuseDetailOpenAlbum = Notification.Name("primuse.detail.openAlbum")
    static let primuseDetailOpenArtist = Notification.Name("primuse.detail.openArtist")
    static let primuseSelectScrobble = Notification.Name("primuse.route.scrobble")
}
#endif
