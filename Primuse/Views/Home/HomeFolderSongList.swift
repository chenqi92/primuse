import Foundation
import Observation
import PrimuseKit

/// 「目录」页打开的那个文件夹自己的歌(6c 单元 4 U9a)。
///
/// The folder's own songs in the chosen order, as IDs, worked out off the main
/// actor once per folder and index revision. Sorting them inside `body`
/// re-sorted a whole source's songs on every refresh — a source root with
/// a few hundred thousand unfoldered songs held the main thread for
/// seconds each time the playing song changed.
///
/// 歌曲模型不在内存里时先后从曲库目录排(`HomeFolderSongs.ordered`),行按页从目录物化(`LibraryListModel`,
/// 可见区上下各约一页),不在视图里逐行同步读目录,也不把一个大文件夹的歌一次物化。
@MainActor
@Observable
final class HomeFolderSongList {
    /// 这份歌是哪个文件夹的。
    private(set) var nodeID: LibraryFolderNodeID?
    /// 文件夹自己的歌,按「目录」页选的顺序,只存 id。
    private(set) var ids: [String] = []
    /// 模型不在内存里时按页从曲库目录物化的行(行号与 `ids` 一一对应);模型在内存里时为 nil,行照旧按 id 从内存取。
    private(set) var rows: LibraryListModel<LibrarySongListQuery>?
    /// 模型不在内存里时正在排、还没有这个文件夹的结果:页面先转圈,不画成空文件夹。
    private(set) var pendingNodeID: LibraryFolderNodeID?
    @ObservationIgnored private var publishedKey: Key?

    init() {}
}

extension HomeFolderSongList {
    /// 什么时候重排这份歌。
    struct Key: Equatable {
        let nodeID: LibraryFolderNodeID?
        let order: HomeFolderSongOrder
        /// 首页模型此刻的索引:文件夹里有哪些歌(扫描、删歌、改名、换源都会发布一份新的)。
        let index: ObjectIdentifier?
        /// 模型在内存里:首页模型的 `revision`,与原来相同(索引发布、封面、播放记录变了都重排一次,在内存里排很便宜)。
        /// 放掉了:nil —— 后台挑好一批封面时 `revision` 也会加一,那不改文件夹里的歌,不该把文件夹重新读一遍。
        let revision: Int?
        /// 放掉了:这个源在曲库目录里的令牌(这个源的行增删、内容改了就变),改到排序用的列时要重排。
        let catalogToken: UInt64?
    }

    static func key(
        nodeID: LibraryFolderNodeID?, order: HomeFolderSongOrder, model: HomeDiscoveryModel, library: MusicLibrary
    ) -> Key {
        let released = !library.isReady
        return Key(
            nodeID: nodeID,
            order: order,
            index: model.index.map(ObjectIdentifier.init),
            revision: released ? nil : model.revision,
            catalogToken: released ? nodeID.flatMap { library.catalogHost?.revisions.token(forSourceID: $0.sourceID) } : nil
        )
    }

    /// Empty until the open folder's own list is ready, never the previous one's.
    func ids(for nodeID: LibraryFolderNodeID?) -> [String] {
        self.nodeID == nodeID ? ids : []
    }

    /// 这个文件夹的歌还在排(第一次),页面上转圈。
    func isPending(_ nodeID: LibraryFolderNodeID?) -> Bool {
        nodeID != nil && pendingNodeID == nodeID && self.nodeID != nodeID
    }

    /// 第 `position` 行(从 0 起)那首。模型不在内存里时取按页物化的那一份:这一页还没到时是 nil(这一行先不画,
    /// 已排期取那一页,到了重画);模型在内存里时照旧按 id 从内存取(`observed`:只让窗口里的行跟着替换重画,Mac 用)。
    func song(at position: Int, id: String, library: MusicLibrary, observed: Bool = false) -> Song? {
        if let rows {
            if let song = rows.item(at: position), song.id == id { return song }
            guard library.isReady else { return nil }
        }
        return observed ? library.visibleSong(id: id) : library.unobservedVisibleSong(id: id)
    }

    /// 排这个文件夹的歌并发布。答不了(目录读不了又等不到模型,或任务取消)时保留原样。
    func refresh(_ key: Key, model: HomeDiscoveryModel, library: MusicLibrary) async {
        guard let nodeID = key.nodeID, let index = model.index else {
            publish(key, nodeID: key.nodeID, ids: [], rows: nil)
            return
        }
        if key.revision == nil, let publishedKey, publishedKey.nodeID == nodeID, publishedKey.order == key.order {
            // 同一个文件夹、同一种顺序,只是这个源在目录里有改动:攒一攒再排(扫描、补全时一秒能写好几次)。
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        // 只在模型不在内存里时转圈(读目录、或要等模型装回来);在内存里排很快,照原来不转。
        if self.nodeID != nodeID, !library.isReady { pendingNodeID = nodeID }
        guard let answer = await HomeFolderSongs.ordered(
            in: nodeID, scope: .displayed, index: index, order: key.order,
            spokenWordSongIDs: model.spokenWordSongIDs, library: library, wait: .page
        ), !Task.isCancelled else { return }
        if self.nodeID == nodeID, ids == answer.ids, (rows != nil) == (answer.rowids != nil) {
            publishedKey = key
            pendingNodeID = nil
            return
        }
        var pages: LibraryListModel<LibrarySongListQuery>?
        if let rowids = answer.rowids, let host = library.catalogHost {
            let list = LibraryListModel(
                query: LibrarySongListQuery(.rows(LibraryRowList(rowids: rowids, revision: 0))),
                reader: host.reader, revisions: host.revisions, pageSize: 100, prefetchDistance: 100
            )
            await list.reload()
            guard !Task.isCancelled else { return }
            list.activate(initialReload: false)
            pages = list
        }
        publish(key, nodeID: nodeID, ids: answer.ids, rows: pages)
    }

    private func publish(
        _ key: Key, nodeID: LibraryFolderNodeID?, ids: [String], rows: LibraryListModel<LibrarySongListQuery>?
    ) {
        if self.rows !== rows { self.rows?.deactivate() }
        self.nodeID = nodeID
        self.ids = ids
        self.rows = rows
        pendingNodeID = nil
        publishedKey = key
    }
}
