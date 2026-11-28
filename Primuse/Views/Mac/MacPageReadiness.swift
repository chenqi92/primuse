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
        case .smartPlaylist, .smartPlaylistDetail:
            // 规则歌单在曲库目录上匹配;AI 歌单、目录读不了时在内存里匹配,页面自己占用并留着上一份(6c U6a)。
            .catalog
        case .albumDetail, .artistDetail:
            // 专辑页的歌、艺人链接按 id 与范围读目录;艺人页的两排专辑与发行分类从目录算(详情页单元)。
            .catalog
        case .listeningStats:
            // 统计页:历史 + 曲库目录(归属、特征表);目录读不了时页面自己装回模型(6c U6b)。
            .catalog
        case .search, .searchCollection:
            // 搜索的歌、专辑、艺人、有声与环境音从目录答;智能搜索、超大范围的搜索自己占用(U7)。
            .catalog
        case .sources, .source, .tool, .recommendationsPanel, .smartPlaylistEditor:
            .legacy
        }
    }

    private static func readiness(for section: LibrarySection) -> LibraryPageReadiness {
        switch section {
        case .radio, .podcasts, .spokenWord:
            // 与 iPhone 的分类相同(`LibraryReadyContent.readiness(for:)`):电台、播客不读曲库,
            // 有声书架自己先摆上次的书架;本机播客、书架在模型不在内存里时从目录分(U8a)。
            .always
        case .playlists, .albums, .songs:
            // 专辑页(`AlbumGridView`)读曲库目录,还读整库数组的那几种(按发行类别筛)自己占用(6c 单元 4 U4a)。
            // 歌曲页(`SongListView`)的平铺列表、排序、页内查找、来源筛选条与「已下载」一列读目录,
            // 目录版式与离线状态补全前的「已下载」自己占用(U5、U5b)。流派页、环境音页读目录(U6a)。
            .catalog
        case .musicVideos, .favorites:
            // MV 页、收藏页从目录读,答不了时(MV 太多、编辑收藏要挑整库专辑)自己占用(U8b)。
            .catalog
        case .artists:
            // 艺术家左栏从目录按页取;去掉只有单曲的专辑艺人、右边的详情还读整库数组,那两处自己占用(U4b)。
            .catalog
        case .genres, .ambient, .statistics, .folders:
            // 流派、环境音(U6a);统计、目录页(U6b:目录索引按目录建)。
            .catalog
        case .releaseDate, .recommendations:
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
