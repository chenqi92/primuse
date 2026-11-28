import Foundation
import Observation
import PrimuseKit

/// 歌曲页「目录」版式的文件夹索引与每个文件夹的歌。原来在 SongListView.swift 里;6c 单元 4 U9b 给它加了曲库目录那条路,
/// 移到这里(原有部分逐行不变,只是方法挪进扩展、去掉 `private`)。
///
/// 歌曲模型不在内存里、曲库目录可读时,页面交来目录的读法(`setCatalog`):每个文件夹的歌在主线程外排
/// (曲目顺序,或跟着列表排序 —— `LibrarySongListFolderOrder`),页面列出的那些行按页从目录物化(`LibraryListModel`),
/// 不再在视图里逐行同步读目录,也不要内存里的整页快照。没交时(模型在内存里)一切照原来。
@MainActor
@Observable
final class LibraryFolderBrowserCache {
    @ObservationIgnored private var indexReference: LibraryFolderIndex?
    @ObservationIgnored private var orderedQueries: [OrderedQueryKey: [String]] = [:]
    private(set) var hasIndex = false
    private(set) var revision = 0
    /// false = 曲目顺序(默认): 一个文件夹通常就是一张专辑, 按碟号/曲号读;
    /// true = 跟随歌曲列表当前的排序。
    var followsListSort = false

    /// 目录的读法与页面的排序;nil 时照内存的做法。
    @ObservationIgnored private(set) var catalog: CatalogContext?
    /// 目录排好了一份(或换了读法)就加一:读文件夹的歌的界面跟着重画。
    private(set) var catalogRevision = 0
    /// 目录答不了眼前这种排法(要整首歌而文件夹比物化上限大,或读失败):页面占用歌曲模型照内存排。
    /// 换了排法或索引才清掉(模型装回来时不清,免得刚放手又放掉、再装)。
    private(set) var catalogNeedsModel = false
    @ObservationIgnored private var catalogAnswers: [CatalogSlot: CatalogAnswer] = [:]
    /// 最近用过的在后面,超过 `catalogSlotLimit` 时从前面丢。
    @ObservationIgnored private var catalogSlotOrder: [CatalogSlot] = []
    @ObservationIgnored private var catalogTasks: [CatalogKey: Task<Void, Never>] = [:]
    /// 整个文件夹按曲目顺序的 id(同原来按目录建的索引直接读出的),按键记一份,不在每次重画时再读。
    /// 跟着列表排序时排好之前也先给它(成员相同)。
    @ObservationIgnored private var catalogTrackActionIDs: [CatalogKey: [String]] = [:]
    @ObservationIgnored private var catalogRowModels: [String: SongListRowModel] = [:]

    init() {}
}

extension LibraryFolderBrowserCache {
    enum QueryScope: Hashable {
        case visible
        case action
    }

    private struct OrderedQueryKey: Hashable {
        let folderRevision: Int
        let rowOrderRevision: Int
        let nodeID: LibraryFolderNodeID
        let scope: QueryScope
        let followsListSort: Bool
    }

    var index: LibraryFolderIndex? {
        _ = revision
        return indexReference
    }

    func publish(_ index: LibraryFolderIndex) {
        indexReference = index
        orderedQueries.removeAll(keepingCapacity: true)
        if !hasIndex { hasIndex = true }
        revision &+= 1
        // 目录那条路:索引换了(扫描、删歌、改名、换源),各文件夹按新索引重排;排好之前照旧给上一份。
        catalogTrackActionIDs.removeAll()
        if catalog != nil, catalogNeedsModel { catalogNeedsModel = false }
    }

    func node(withID id: LibraryFolderNodeID) -> LibraryFolderNode? {
        index?.node(withID: id)
    }

    func children(of id: LibraryFolderNodeID) -> [LibraryFolderNode] {
        index?.children(of: id) ?? []
    }

    func rootNodes(sourceID: String?) -> [LibraryFolderNode] {
        guard let index else { return [] }
        return LibraryFolderBrowsePolicy.rootNodes(in: index, sourceID: sourceID)
    }

    func orderedSongIDs(
        in nodeID: LibraryFolderNodeID,
        scope: QueryScope,
        listCache: SongListCache
    ) -> [String] {
        if let catalog { return catalogSongIDs(in: nodeID, scope: scope, context: catalog) }
        let rowOrderRevision = listCache.rowOrderRevision
        let key = OrderedQueryKey(
            folderRevision: revision,
            rowOrderRevision: rowOrderRevision,
            nodeID: nodeID,
            scope: scope,
            followsListSort: followsListSort
        )
        if let cached = orderedQueries[key] { return cached }
        guard let index else { return [] }

        if !followsListSort {
            let ordered = LibraryFolderBrowsePolicy.trackOrderedSongIDs(
                in: nodeID,
                scope: scope == .visible ? .direct : .descendants,
                index: index,
                isVisible: listCache.isEmpty ? { _ in true } : { listCache.contains(songID: $0) }
            )
            orderedQueries[key] = ordered
            return ordered
        }

        let ordered: [String]
        switch scope {
        case .visible:
            ordered = LibraryFolderBrowsePolicy.visibleSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        case .action:
            ordered = LibraryFolderBrowsePolicy.actionSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        }
        orderedQueries[key] = ordered
        return ordered
    }
}

// MARK: - The catalog path (6c unit 4 U9b)

extension LibraryFolderBrowserCache {
    /// 目录的读法与页面此刻的排序。
    struct CatalogContext {
        let host: LibraryCatalogHost
        /// 页面列表的排序(跟着列表排序时用)。
        let listOrder: LibrarySongSortOrder
        /// 页面内存排序用的那份排序值(iOS 是空的;Mac 带本机播放次数、源名、文件名索引)。
        let sortValues: SongListSortValues
        /// 排序值的修订号(`SongListSortValuesVersion`);排序值变了它就变。
        let sortRevision: UUID?
    }

    /// 一个文件夹的一份答案是照什么排的。
    struct CatalogKey: Hashable {
        let folderRevision: Int
        let nodeID: LibraryFolderNodeID
        let scope: QueryScope
        /// nil = 曲目顺序。
        let listOrder: LibrarySongSortOrder?
        let sortRevision: UUID?
        /// 跟着列表排序时:这个源在目录里的令牌(这个源的行增删、内容改了就变,改到排序的列要重排)。曲目顺序只随索引变。
        let sourceToken: UInt64?
    }

    /// 页面上一个位置(哪个文件夹、它自己的歌还是整棵子树)。
    struct CatalogSlot: Hashable {
        let nodeID: LibraryFolderNodeID
        let scope: QueryScope
    }

    struct CatalogAnswer {
        let key: CatalogKey
        let ids: [String]
        /// 文件夹自己的歌:按页物化的行(行号与 `ids` 一一对应)。整棵子树那一份不画行,为 nil。
        let rows: LibraryListModel<LibrarySongListQuery>?
    }

    /// 同时留着几个文件夹的答案(推入的几层页面、Mac 眼前那一层,各自的歌与整棵子树)。
    static let catalogSlotLimit = 12

    /// 要整首歌才能排的顺序在目录上一次至多排多少首,超过就占用模型照内存排(测试里改小)。
    static var catalogSongLimit = LibraryScale.maxMaterializedRows

    /// 「播放全部」能不能按这个文件夹整棵子树的先后播了:不在目录那条路上时总能;跟着列表排序时要等排好
    /// (排好之前给的是曲目顺序的那份,成员对、先后不对)。
    func actionIDsReady(in nodeID: LibraryFolderNodeID) -> Bool {
        _ = catalogRevision
        return catalog == nil || hasCatalogAnswer(in: nodeID, scope: .action)
    }

    /// 这个位置有没有照眼前这种排法排好的答案(排好之前给的是上一份或曲目顺序的那份)。
    func hasCatalogAnswer(in nodeID: LibraryFolderNodeID, scope: QueryScope) -> Bool {
        _ = catalogRevision
        guard let catalog else { return false }
        let slot = CatalogSlot(nodeID: nodeID, scope: scope)
        let key = catalogKey(for: slot, context: catalog)
        return (scope == .action && key.listOrder == nil) || catalogAnswers[slot]?.key == key
    }

    /// 跟着列表排序时目录排不出、仍要占用模型的排序:Mac 的「已下载」要页面在整库数组上探测出的已下载集合
    /// (`downloadedSongIDs`)。iOS 的内存排序不带排序值(全是空的),「已下载」在目录上一样排得出。
    static func catalogServes(followsListSort: Bool, order: LibrarySongSortOrder) -> Bool {
        #if os(macOS)
        return !followsListSort || order.criterion != .downloaded
        #else
        return true
        #endif
    }

    /// 页面在模型在不在、目录可不可读、排序、排序值变了时交来;nil = 照内存的做法。
    /// 「要模型」在模型又放掉了(页面不在眼前或进了后台时才放得掉)、或换了排法时清掉,再试一次目录。
    func setCatalog(_ context: CatalogContext?) {
        let previous = catalog
        catalog = context
        if let context, catalogNeedsModel,
           previous.map({ $0.listOrder != context.listOrder || $0.sortRevision != context.sortRevision }) ?? true {
            catalogNeedsModel = false
        }
        if context == nil {
            for task in catalogTasks.values { task.cancel() }
            catalogTasks.removeAll()
            catalogTrackActionIDs.removeAll()
            for answer in catalogAnswers.values { answer.rows?.deactivate() }
            catalogAnswers.removeAll()
            catalogSlotOrder.removeAll()
            catalogRowModels.removeAll()
        }
        catalogRevision &+= 1
    }

    /// 整个文件夹(连同子文件夹)有哪些歌,给只看成员的地方:多选时文件夹行的勾选与计数、文件夹行长按的「全选」
    /// 「专辑元数据」(那张表自己按专辑、碟号、曲号排)。目录那条路上给曲目顺序的那份(成员与跟着排序的相同),
    /// 不为每一行文件夹在后台排一遍;不在目录那条路上时照原来(`orderedSongIDs(in:scope: .action)`)。
    func memberSongIDs(in nodeID: LibraryFolderNodeID, listCache: SongListCache) -> [String] {
        _ = catalogRevision
        guard catalog != nil, let index = indexReference else {
            return orderedSongIDs(in: nodeID, scope: .action, listCache: listCache)
        }
        return trackActionIDs(in: nodeID, index: index)
    }

    /// 文件夹的歌此刻从目录排(页面交了目录的读法)。
    var servesFromCatalog: Bool {
        _ = catalogRevision
        return catalog != nil
    }

    /// 目录那条路上这个文件夹自己的歌还没有第一份答案(页面先转圈,不画成空文件夹)。
    func isCatalogPending(_ nodeID: LibraryFolderNodeID) -> Bool {
        _ = catalogRevision
        guard catalog != nil else { return false }
        return catalogAnswers[CatalogSlot(nodeID: nodeID, scope: .visible)] == nil
    }

    /// 文件夹页第 `position` 行的行模型。目录那条路:按页物化的那首,这一页还没到时是 nil(这一行先不画,已排期取那一页,
    /// 到了重画);内容变了(目录重新物化出不同的值)换一个新的模型。不在目录那条路上时是 nil,调用方照原来取。
    func catalogRowModel(in nodeID: LibraryFolderNodeID, at position: Int, id: String) -> SongListRowModel? {
        _ = catalogRevision
        guard let answer = catalogAnswers[CatalogSlot(nodeID: nodeID, scope: .visible)],
              let song = answer.rows?.item(at: position), song.id == id else { return nil }
        if let model = catalogRowModels[id], model.song == song { return model }
        let model = SongListRowModel(song: song)
        if catalogRowModels.count >= 600 { catalogRowModels.removeAll(keepingCapacity: true) }
        catalogRowModels[id] = model
        return model
    }

    private func catalogSongIDs(in nodeID: LibraryFolderNodeID, scope: QueryScope, context: CatalogContext) -> [String] {
        _ = catalogRevision
        guard let index = indexReference else { return [] }
        let slot = CatalogSlot(nodeID: nodeID, scope: scope)
        let key = catalogKey(for: slot, context: context)
        if scope == .action, key.listOrder == nil { return trackActionIDs(in: nodeID, index: index) }
        touch(slot)
        let current = catalogAnswers[slot]
        if current?.key == key, let current { return current.ids }
        scheduleCatalogAnswer(key, index: index, context: context, replacing: current?.key)
        // 排好之前:同一个位置的上一份照旧给(换排序、索引、目录内容时不闪空);第一次打开时文件夹自己的歌先空着(页面转圈),
        // 整个文件夹那一份先给曲目顺序的 id(成员相同:全选、修剪多选用的是成员)。
        if let current { return current.ids }
        return scope == .action ? trackActionIDs(in: nodeID, index: index) : []
    }

    /// 整个文件夹按曲目顺序:就是索引里的先后,同原来按目录建的索引那样读出 id(播放全部、全选、修剪多选、批量操作)。
    /// 按索引的修订号与节点记一份,不在每次重画时再读。
    private func trackActionIDs(in nodeID: LibraryFolderNodeID, index: LibraryFolderIndex) -> [String] {
        let trackKey = CatalogKey(folderRevision: revision, nodeID: nodeID, scope: .action, listOrder: nil,
                                  sortRevision: nil, sourceToken: nil)
        if let cached = catalogTrackActionIDs[trackKey] { return cached }
        let ids = index.songIDs(in: nodeID, scope: .descendants)
        catalogTrackActionIDs[trackKey] = ids
        return ids
    }

    private func catalogKey(for slot: CatalogSlot, context: CatalogContext) -> CatalogKey {
        let listOrder = followsListSort ? context.listOrder : nil
        return CatalogKey(
            folderRevision: revision,
            nodeID: slot.nodeID,
            scope: slot.scope,
            listOrder: listOrder,
            sortRevision: listOrder == nil ? nil : context.sortRevision,
            sourceToken: listOrder == nil ? nil : context.host.revisions.token(forSourceID: slot.nodeID.sourceID)
        )
    }

    private func touch(_ slot: CatalogSlot) {
        if catalogSlotOrder.last == slot { return }
        let trimsUnanswered = catalogSlotOrder.count > 64
        catalogSlotOrder.removeAll { $0 == slot || (trimsUnanswered && catalogAnswers[$0] == nil) }
        catalogSlotOrder.append(slot)
    }

    /// 在主线程外排这个文件夹(`LibrarySongListFolderOrder`);自己的歌另外建按页物化的行。排好换上、旧的那份放掉。
    /// 同一个位置只是目录内容变了(扫描、补全一秒能写好几次):先攒 300 毫秒再排;排出来与眼前相同就只换键。
    private func scheduleCatalogAnswer(
        _ key: CatalogKey, index: LibraryFolderIndex, context: CatalogContext, replacing previous: CatalogKey?
    ) {
        guard catalogTasks[key] == nil, !catalogNeedsModel else { return }
        // 一个位置同时只排一份:换了排法、索引或目录内容时,还在排的旧的那份不要了。
        for (other, task) in catalogTasks where other.nodeID == key.nodeID && other.scope == key.scope {
            task.cancel()
            catalogTasks[other] = nil
        }
        let debounce = previous.map {
            $0.folderRevision == key.folderRevision && $0.listOrder == key.listOrder && $0.sortRevision == key.sortRevision
        } ?? false
        let sortValues = context.sortValues
        let host = context.host
        let songLimit = Self.catalogSongLimit
        catalogTasks[key] = Task { @MainActor [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            let folderScope: LibraryFolderSongScope = key.scope == .visible ? .direct : .descendants
            let answer: LibraryFolderCatalogSongOrder.Ordered?
            do {
                answer = try await host.reader.readCancellable { catalog, cancellation in
                    try LibrarySongListFolderOrder.ordered(
                        in: key.nodeID, scope: folderScope, index: index, listOrder: key.listOrder,
                        sortValues: sortValues, catalog: catalog, songLimit: songLimit,
                        isCancelled: { cancellation.isCancelled }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                plog("⚠️ Songs page folder order from the catalog failed, using the song model: \(error)")
                answer = nil
            }
            guard let self, !Task.isCancelled else { return }
            guard let answer else {
                // 要整首歌而文件夹太大,或读失败:页面占用模型照内存排(「答不了」不当成空文件夹)。
                self.catalogTasks[key] = nil
                if self.catalog != nil, !self.catalogNeedsModel { self.catalogNeedsModel = true }
                return
            }
            let slot = CatalogSlot(nodeID: key.nodeID, scope: key.scope)
            if let current = self.catalogAnswers[slot], current.ids == answer.ids {
                // 与眼前的相同(同样的歌、同样的先后,行号也就相同):只换键,行照旧。
                self.catalogTasks[key] = nil
                self.store(CatalogAnswer(key: key, ids: current.ids, rows: current.rows), in: slot, keepingRows: true)
                return
            }
            var rows: LibraryListModel<LibrarySongListQuery>?
            if key.scope == .visible {
                let list = LibraryListModel(
                    query: LibrarySongListQuery(.rows(LibraryRowList(rowids: answer.rowids, revision: 0))),
                    reader: host.reader, revisions: host.revisions, pageSize: 100, prefetchDistance: 100
                )
                await list.reload()
                guard !Task.isCancelled else { return }
                list.activate(initialReload: false)
                rows = list
            }
            self.catalogTasks[key] = nil
            guard self.catalog != nil else {
                rows?.deactivate()
                return
            }
            self.store(CatalogAnswer(key: key, ids: answer.ids, rows: rows), in: slot, keepingRows: false)
        }
    }

    private func store(_ answer: CatalogAnswer, in slot: CatalogSlot, keepingRows: Bool) {
        if !keepingRows, let old = catalogAnswers[slot]?.rows, old !== answer.rows { old.deactivate() }
        catalogAnswers[slot] = answer
        touch(slot)
        // 自己的歌留最近的几份;整棵子树那份(只在跟着列表排序时、只为打开着的文件夹页排,源的根就是这个源的全部 id)
        // 留四份(推入的几层页面各一份)。只在同一种里丢。
        let limit = slot.scope == .visible ? Self.catalogSlotLimit : Self.catalogSlotLimit / 3
        while catalogSlotOrder.filter({ $0.scope == slot.scope && catalogAnswers[$0] != nil }).count > limit,
              let evicted = catalogSlotOrder.first(where: { $0.scope == slot.scope && catalogAnswers[$0] != nil }) {
            catalogSlotOrder.removeAll { $0 == evicted }
            catalogAnswers.removeValue(forKey: evicted)?.rows?.deactivate()
        }
        catalogRevision &+= 1
    }
}
