import Foundation
import PrimuseKit

// 不按平台包起来:iOS 的测试目标也编这个文件,在那里测每一页的显示规则。

/// Mac 主窗口里的一页:侧栏选中的一项、标题栏的搜索、详情栈压进来的一页、弹框与右侧面板。
/// 只用来定它在歌曲模型不在内存里时怎么显示(6c 单元 4 U2b):主窗口整体等「曲库可用」(`isUsable`),
/// 每一页再按 `readiness` —— 改成读曲库目录的页随可用就画,还读整库数组的页显示加载并替自己占用模型。
enum MacPageKind: Hashable, Sendable {
    case home
    case listeningStats
    case sources
    case source
    case search
    case section(LibrarySection)
    case likedSongs
    case playlist
    case smartPlaylist
    /// 详情栈里压进来的一页。
    case albumDetail
    case artistDetail
    case playlistDetail
    case smartPlaylistDetail
    case searchCollection
    case appleMusicArtist
    case spokenWordBook
    /// 标题栏「工具」里的弹框(缓存同步、设备互传、歌词转换、重复歌曲)。
    case tool
    /// 右侧的智能推荐面板。
    case recommendationsPanel
    /// 新建智能歌单、AI 歌单的编辑器。
    case smartPlaylistEditor
}

extension MacPageKind {
    /// 这一页此刻的显示规则。还读整库数组的页随各自的单元改过来,一页改一行。
    var readiness: LibraryPageReadiness {
        switch self {
        case .home:
            // U2a:首页从目录读,推荐沿用上一份。
            .catalog
        case .likedSongs, .playlist, .playlistDetail:
            // 歌单的歌按 id 取(`songs(forPlaylist:)`,模型不在内存里时由目录作答),计数与摘要在 19a 改过。
            .catalog
        case .section(let section):
            Self.readiness(for: section)
        case .appleMusicArtist:
            // Apple Music 目录里的艺人,不读本地曲库。
            .always
        case .spokenWordBook:
            // 书的章节随书架从目录分(`SpokenWordCatalogShelf`,U8a)。
            .catalog
        case .listeningStats, .sources, .source, .search, .smartPlaylist, .albumDetail, .artistDetail,
             .smartPlaylistDetail, .searchCollection, .tool, .recommendationsPanel, .smartPlaylistEditor:
            .legacy
        }
    }

    private static func readiness(for section: LibrarySection) -> LibraryPageReadiness {
        switch section {
        case .radio, .podcasts, .spokenWord:
            // 与 iPhone 的分类相同(`LibraryReadyContent.readiness(for:)`):电台、播客不读曲库,
            // 有声书架自己先摆上次的书架;本机播客、书架在模型不在内存里时从目录分(U8a)。
            .always
        case .playlists, .albums:
            // 专辑页(`AlbumGridView`)读曲库目录,还读整库数组的那几种(按发行类别筛)自己占用(6c 单元 4 U4a)。
            .catalog
        case .musicVideos, .favorites:
            // MV 页、收藏页从目录读,答不了时(MV 太多、编辑收藏要挑整库专辑)自己占用(U8b)。
            .catalog
        case .songs, .artists, .genres, .folders, .releaseDate, .recommendations, .statistics, .ambient:
            .legacy
        }
    }

    /// 收用户输入的页:显示过内容之后模型被放掉也不换成加载页,盖一层加载(`SongModelPageLatch`,UB)。
    var keepsInputOnRelease: Bool {
        self == .smartPlaylistEditor
    }

    /// 按规则此刻能不能画(`LibraryPageReadiness.showsContent`)。主窗口本身等到可用才出来,
    /// 所以 `.catalog` 在窗口里总是画的。
    static func showsContent(_ readiness: LibraryPageReadiness, isUsable: Bool, isReady: Bool) -> Bool {
        readiness.showsContent(isUsable: isUsable, isReady: isReady)
    }
}
