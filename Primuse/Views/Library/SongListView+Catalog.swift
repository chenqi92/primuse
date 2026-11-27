import Foundation
import Observation
import PrimuseKit

/// 歌曲页(整库或一个源)平铺列表在曲库目录上的数据源(P2a)。
///
/// 按排序与范围持有一个 `LibraryListModel`(整列行号,按页物化),外加页头要的计数。换排序、
/// 换来源时新的一份取好之前照旧显示上一份,与内存路径「新快照排好之前显示旧顺序」一致。
/// 目录读失败时记下那个键,页面退回内存路径(`failedKey`)。
@MainActor
@Observable
final class SongListCatalogList {

    private var current: Entry?
    private(set) var summary: Summary?
    /// 这个键在目录上取失败了;页面对这个键走内存路径。
    private(set) var failedKey: Key?
    /// 换过一份列表就加一。
    private(set) var swapRevision = 0

    @ObservationIgnored private var pending: Entry?
    @ObservationIgnored private var summaryBaseScope: LibrarySongScope?
    @ObservationIgnored private var summaryListScope: LibrarySongScope?
    @ObservationIgnored private var reader: LibraryCatalogReader?
    @ObservationIgnored private weak var revisions: LibraryCatalogRevisions?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var rowModels: [String: SongListRowModel] = [:]
    /// 多选进行中时这份列表的歌曲 id(按显示顺序);全选、范围选择、批量操作排序用。
    @ObservationIgnored private(set) var selectionIDs: [String]?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var wantsSelectionIDs = false
    /// 多选用的 id 取好之后回调(页面拿它修剪已选项)。
    @ObservationIgnored var selectionIDsDidLoad: (@MainActor ([String]) -> Void)?

    init() {}
}

extension SongListCatalogList {
    struct Key: Equatable, Sendable {
        let order: LibrarySongSortOrder
        /// 列表的范围(Mac 选了来源筛选时只是那一个源)。
        let scope: LibrarySongScope
        /// 整页的范围:页头的歌曲数、可播放数、总时长与来源筛选条上的计数按它算。
        let baseScope: LibrarySongScope
    }

    struct Summary: Equatable, Sendable {
        var base: LibraryRowList.Aggregates
        var list: LibraryRowList.Aggregates
        /// 只在 Mac 上取(来源筛选条)。
        var countsBySource: [String: Int]
        /// 只在 Mac 上取(页头大封面):整页范围里库内顺序第一首有封面的歌。
        var coverSong: Song?
    }

    private struct Entry {
        let key: Key
        let model: LibraryListModel<LibrarySongListQuery>
    }

    var hasCurrent: Bool { current != nil }
    var currentKey: Key? { current?.key }
    var count: Int { current?.model.count ?? 0 }
    var sections: [SongListSectionIndexEntry] { current?.model.sections ?? [] }
    /// 行号整体换过(换了排序或范围、成员变了)就变;定位、字母条据此对账。
    var rowRevision: Int {
        swapRevision &* 1_048_576 &+ Int(truncatingIfNeeded: current?.model.listGeneration ?? 0)
    }
    /// 整页范围的歌曲数;还没取到时为 nil。
    var baseCount: Int? { summary?.base.count }
    var basePlayableCount: Int { summary?.base.playableCount ?? 0 }
    var baseTotalDuration: TimeInterval { summary?.base.totalDuration ?? 0 }
    var listPlayableCount: Int { summary?.list.playableCount ?? 0 }
    var coverSong: Song? { summary?.coverSong }

    func songCount(forSourceID sourceID: String) -> Int {
        summary?.countsBySource[sourceID] ?? 0
    }

    func isCurrentOrPending(_ key: Key) -> Bool {
        current?.key == key || pending?.key == key
    }

    /// 第 `index` 行的歌;那一页还没取到时为 nil(占位行),同时排期取那一页。
    func song(at index: Int) -> Song? {
        current?.model.item(at: index)
    }

    /// 行用的模型。内容变了(目录重新物化出不同的值)就换一个新的,行跟着重画。
    func rowModel(for song: Song) -> SongListRowModel {
        if let model = rowModels[song.id], model.song == song { return model }
        let model = SongListRowModel(song: song)
        if rowModels.count >= 600 { rowModels.removeAll(keepingCapacity: true) }
        rowModels[song.id] = model
        return model
    }

    /// 让 `key` 那一份成为当前显示的列表:第一次取行号(与页头计数)好了才换上。
    /// 返回 false 表示被别的键取代、任务取消或目录读失败(此时记下 `failedKey`)。
    func prepare(key: Key, host: LibraryCatalogHost) async -> Bool {
        attach(host)
        if current?.key == key { return true }
        if pending?.key != key {
            pending?.model.deactivate()
            let model = host.songList(.sorted(key.order, key.scope))
            model.activate()
            pending = Entry(key: key, model: model)
        }
        while let entry = pending, entry.key == key, entry.model.isLoading {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return false
            }
        }
        guard let entry = pending, entry.key == key else { return current?.key == key }
        if let error = entry.model.lastError {
            plog("📚 catalog song list failed order=\(key.order.rawValue): \(error)")
            entry.model.deactivate()
            pending = nil
            failedKey = key
            return false
        }
        if summaryBaseScope != key.baseScope || summaryListScope != key.scope {
            await loadSummary(for: key)
            guard let stillPending = pending, stillPending.key == key else { return current?.key == key }
        }
        current?.model.deactivate()
        current = entry
        pending = nil
        if failedKey != nil { failedKey = nil }
        swapRevision &+= 1
        rowModels.removeAll()
        if wantsSelectionIDs { reloadSelectionIDs() }
        return true
    }

    /// 页面离开目录路径:正在取的那一份不要了。眼前那一份留着(回来时同一个键直接显示)。
    func cancelPending() {
        pending?.model.deactivate()
        pending = nil
    }

    /// 目录不可读了:全部放掉。
    func reset() {
        cancelPending()
        current?.model.deactivate()
        current = nil
        summary = nil
        summaryBaseScope = nil
        summaryListScope = nil
        failedKey = nil
        summaryTask?.cancel()
        selectionTask?.cancel()
        selectionIDs = nil
        rowModels.removeAll()
        swapRevision &+= 1
    }

    /// 眼前这份列表的歌曲 id(按显示顺序)。只在播放、多选这些动作里取,不进 body。
    func orderedSongIDs() async -> [String]? {
        guard let entry = current, let reader else { return nil }
        let model = entry.model
        var rowids = ContiguousArray<Int32>()
        rowids.reserveCapacity(model.count)
        for index in 0..<model.count {
            if let rowid = model.rowid(at: index) { rowids.append(rowid) }
        }
        do {
            return try await reader.songIDs(rowids: rowids, scope: entry.key.scope)
        } catch {
            plog("📚 catalog song list ids failed: \(error)")
            return nil
        }
    }

    /// 某首歌在眼前这份列表里的位置(定位用)。
    func position(of songID: String) async -> Int? {
        guard let entry = current, let reader else { return nil }
        let resolved = try? await reader.rowids(forIDs: [songID])
        guard let rowid = resolved?.first ?? nil, current?.key == entry.key else { return nil }
        let model = entry.model
        for index in 0..<model.count where model.rowid(at: index) == rowid {
            return index
        }
        return nil
    }

    /// 多选开始 / 结束。开始时按显示顺序取一次 id,列表换了再取。
    func setWantsSelectionIDs(_ wants: Bool) {
        wantsSelectionIDs = wants
        if wants {
            reloadSelectionIDs()
        } else {
            selectionTask?.cancel()
            selectionTask = nil
            selectionIDs = nil
        }
    }

    // MARK: - Private

    private func reloadSelectionIDs() {
        selectionTask?.cancel()
        guard current != nil else { return }
        selectionTask = Task { [weak self] in
            guard let self else { return }
            let ids = await self.orderedSongIDs()
            guard !Task.isCancelled, self.wantsSelectionIDs, let ids else { return }
            self.selectionIDs = ids
            self.selectionIDsDidLoad?(ids)
        }
    }

    private func attach(_ host: LibraryCatalogHost) {
        if reader == nil { reader = host.reader }
        guard revisions !== host.revisions else { return }
        revisions = host.revisions
        host.revisions.addListener { [weak self] _ in
            guard let self else { return false }
            self.catalogDidChange()
            return true
        }
    }

    /// 目录变了:列表模型自己重查行号;这里防抖后重取页头计数,多选中的 id 也跟着换。
    private func catalogDidChange() {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let key = self.current?.key else { return }
            await self.loadSummary(for: key)
            if self.wantsSelectionIDs { self.reloadSelectionIDs() }
        }
    }

    private func loadSummary(for key: Key) async {
        guard let reader else { return }
        #if os(macOS)
        let detailed = true
        #else
        let detailed = false
        #endif
        do {
            let next = try await reader.read { catalog -> Summary in
                let base = try catalog.aggregates(key.baseScope)
                let list: LibraryRowList.Aggregates
                if key.scope == key.baseScope {
                    list = base
                } else {
                    list = try catalog.aggregates(key.scope)
                }
                var countsBySource: [String: Int] = [:]
                var cover: Song?
                if detailed {
                    countsBySource = try catalog.songCountsBySource(key.baseScope)
                    try catalog.forEachSong(key.baseScope) { _, song in
                        if song.coverArtFileName?.isEmpty == false {
                            cover = song
                            return false
                        }
                        return true
                    }
                }
                return Summary(base: base, list: list, countsBySource: countsBySource, coverSong: cover)
            }
            summaryBaseScope = key.baseScope
            summaryListScope = key.scope
            if summary != next { summary = next }
        } catch {
            plog("📚 catalog song list summary failed: \(error)")
        }
    }
}

/// 歌曲页在目录上能给出与内存路径一模一样结果的排序。
enum SongListCatalogPolicy {
    /// - 播放次数、已下载:目录还没有这两张设备状态表的数据(`songStat`、`songOffline` 没人写),走内存。
    /// - 来源(iOS):iOS 的内存排序不带源名、按源 id 比,目录按源名比,走内存;Mac 两边都按源名。
    static func supports(_ order: LibrarySongSortOrder) -> Bool {
        switch order.criterion {
        case .title, .fileName, .artist, .album, .dateAdded, .sourceDate, .format, .duration,
                .serverPlayCount, .year, .bitRate, .bitDepth:
            return true
        case .source:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        case .playCount, .downloaded:
            return false
        }
    }
}
