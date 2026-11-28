import Foundation
import Observation
import PrimuseKit

/// 一个列表的行(歌曲行号,或专辑/艺人的键)与分节索引。
struct LibraryListRows: Sendable, Equatable {
    var ids: ContiguousArray<Int32>
    var sections: [SongListSectionIndexEntry]
    var revision: Int64
    /// 专辑墙、艺人墙的分段(首字母或年代),与 `ids` 一一对应。
    var browseSections: [LibraryBrowseSection] = []
    /// 查找结果的汇总(歌曲页页头的可播放数);其余列表为 nil。不算进「行号换没换」。
    var aggregates: LibraryRowList.Aggregates?

    static let empty = LibraryListRows(ids: [], sections: [], revision: 0)
}

/// 歌曲页「播放次数」排序用的计数(歌曲 id → 本机播放次数,播放记录折出来的)。
/// 比较只看修订号:计数一换,页面给的修订号就换,不必逐项比字典。
struct LibrarySongPlayCounts: Sendable, Equatable {
    let revision: UUID?
    let counts: [String: Int]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }
}

/// 列表模型的数据来源:怎么取整列的行号、怎么按行号物化、哪些变化要重查。
protocol LibraryListQuery: Sendable {
    associatedtype Item: Sendable
    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows
    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Item]
    func isAffected(by change: LibraryCatalogChange) -> Bool
}

/// 歌曲列表:排序列表、专辑、艺人、书、文件夹、任意范围。物化经全局行缓存。
struct LibrarySongListQuery: LibraryListQuery {
    enum Content: Sendable, Equatable {
        case sorted(LibrarySongSortOrder, LibrarySongScope)
        case scope(LibrarySongScope)
        case album(String)
        case artist(String)
        case book(String)
        case folder(sourceID: String, path: String, recursive: Bool)
        case rows(LibraryRowList)
        /// 按本机播放次数排(次数在播放记录里,不在目录里)。
        case playCounts(LibrarySongPlayCounts, ascending: Bool, LibrarySongScope)
    }

    let content: Content
    /// 页内查找:只留匹配的行(顺序不变)。
    let find: LibraryFindPolicy.Query?
    /// 「来源」排序给源排名用源名还是源 id(与页面的内存排序一致,见 `LibrarySongSourceRanking`)。
    let sourceRanking: LibrarySongSourceRanking

    init(_ content: Content, find: LibraryFindPolicy.Query? = nil, sourceRanking: LibrarySongSourceRanking = .name) {
        self.content = content
        self.find = find
        self.sourceRanking = sourceRanking
    }

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        var list: LibraryRowList
        switch content {
        case .sorted(let order, let scope):
            list = try catalog.songRowList(order: order, scope: scope, sourceRanking: sourceRanking)
        case .playCounts(let counts, let ascending, let scope):
            list = try catalog.songRowList(playCounts: counts.counts, ascending: ascending, scope: scope)
        case .scope(let scope): list = try catalog.rowList(scope)
        case .album(let albumID): list = try catalog.albumSongRowList(albumID: albumID)
        case .artist(let artistID): list = try catalog.artistSongRowList(artistID: artistID)
        case .book(let bookID): list = try catalog.bookRowList(bookID: bookID)
        case .folder(let sourceID, let path, let recursive):
            list = try catalog.rowList(sourceID: sourceID, directory: path, recursive: recursive)
        case .rows(let rows): list = rows
        }
        if let find { list = try catalog.songRowList(list, matching: find) }
        return LibraryListRows(ids: list.rowids, sections: list.sections, revision: list.revision, aggregates: list.aggregates)
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Song] {
        let songs = try rowCache.songs(forRowids: ids, in: catalog)
        var result: [Int32: Song] = [:]
        for (rowid, song) in zip(ids, songs) where song != nil { result[rowid] = song }
        return result
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool {
        if case .rows = content { return !change.updatedRowids.isEmpty || change.changesMembership }
        if change.invalidatesEverything || change.changesMembership { return true }
        // 只改了内容:排序可能变,范围限定在源上时只看这个源。
        switch content {
        case .sorted(_, let scope), .scope(let scope), .playCounts(_, _, let scope):
            if let sourceID = scope.sourceID, let touched = change.touchedSourceIDs { return touched.contains(sourceID) }
            return !change.updatedRowids.isEmpty
        default:
            return !change.updatedRowids.isEmpty
        }
    }
}

/// 专辑网格:按目录的专辑顺序(标题本地化排序)。
struct LibraryAlbumListQuery: LibraryListQuery {
    var visibleOnly = true

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let keys = try catalog.albumKeys(visibleOnly: visibleOnly)
        return LibraryListRows(ids: keys.keys, sections: [], revision: keys.revision)
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Album] {
        // `albums(keys:)` 保持顺序、跳过不在的键;数目对得上就逐个对回键,否则一个个取。
        let albums = try catalog.albums(keys: ids, visibleCounts: visibleOnly)
        if albums.count == ids.count {
            return Dictionary(uniqueKeysWithValues: zip(ids, albums))
        }
        var result: [Int32: Album] = [:]
        for key in ids {
            if let album = try catalog.albums(keys: [key], visibleCounts: visibleOnly).first { result[key] = album }
        }
        return result
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}

/// 艺人列表:按目录的艺人顺序(名字本地化排序)。
struct LibraryArtistListQuery: LibraryListQuery {
    var visibleOnly = true

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let keys = try catalog.artistKeys(visibleOnly: visibleOnly)
        return LibraryListRows(ids: keys.keys, sections: [], revision: keys.revision)
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Artist] {
        let artists = try catalog.artists(keys: ids, visibleCounts: visibleOnly)
        if artists.count == ids.count {
            return Dictionary(uniqueKeysWithValues: zip(ids, artists))
        }
        var result: [Int32: Artist] = [:]
        for key in ids {
            if let artist = try catalog.artists(keys: [key], visibleCounts: visibleOnly).first { result[key] = artist }
        }
        return result
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}

/// 资料库列表(歌曲、专辑、艺人)在 P2 的数据源:持有整列行号(4 字节一行),按页从目录取,
/// 只把可见区上下各 `prefetchDistance` 行物化在内存里。
///
/// 用法(SwiftUI):
/// ```swift
/// List(0..<model.count, id: \.self) { index in
///     if let song = model.item(at: index) { SongRow(song) } else { SongRowPlaceholder() }
/// }
/// .onAppear { model.activate() }
/// ```
/// `item(at:)` 拿不到时返回 nil(占位行),同时排期取那一页;页到了 `loadedGeneration` 变化,
/// 读过它的行会重画。目录有相关变化时防抖后在主线程外重查,换掉行号、保留还在的已物化行。
@MainActor
@Observable
final class LibraryListModel<Query: LibraryListQuery> {
    let query: Query
    private(set) var count = 0
    private(set) var sections: [SongListSectionIndexEntry] = []
    /// 专辑墙、艺人墙的分段(见 `LibraryListRows.browseSections`)。
    private(set) var browseSections: [LibraryBrowseSection] = []
    /// 查找结果的汇总(见 `LibraryListRows.aggregates`)。
    private(set) var aggregates: LibraryRowList.Aggregates?
    /// 第一次取行号还没回来。
    private(set) var isLoading = true
    /// 行号整体换过就加一(滚动位置、选择据此对账)。
    private(set) var listGeneration: UInt64 = 0
    /// 有新的一页物化好了就加一。
    private(set) var loadedGeneration: UInt64 = 0
    private(set) var lastError: String?

    @ObservationIgnored private let reader: LibraryCatalogReader
    @ObservationIgnored private weak var revisions: LibraryCatalogRevisions?
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var rows = LibraryListRows.empty
    @ObservationIgnored private var loaded: [Int32: Query.Item] = [:]
    @ObservationIgnored private var requestedPages: Set<Int> = []
    @ObservationIgnored private var focusIndex = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration: UInt64 = 0
    @ObservationIgnored private var pageTasks: [Int: Task<Void, Never>] = [:]
    let pageSize: Int
    let prefetchDistance: Int
    let debounce: Duration

    init(
        query: Query,
        reader: LibraryCatalogReader,
        revisions: LibraryCatalogRevisions?,
        pageSize: Int = 200,
        prefetchDistance: Int = 150,
        debounce: Duration = .milliseconds(250)
    ) {
        self.query = query
        self.reader = reader
        self.revisions = revisions
        self.pageSize = max(1, pageSize)
        self.prefetchDistance = max(0, prefetchDistance)
        self.debounce = debounce
    }
}

extension LibraryListModel {
    /// 开始跟踪目录变化并取第一次行号。重复调用无效。
    /// `initialReload` 为 false:调用方已经 `reload()` 过,只开始跟踪变化。
    func activate(initialReload: Bool = true) {
        guard listenerID == nil else { return }
        listenerID = revisions?.addListener { [weak self] change in
            guard let self else { return false }
            self.catalogDidChange(change)
            return true
        }
        if initialReload { scheduleReload(after: .zero) }
    }

    func deactivate() {
        if let listenerID { revisions?.removeListener(listenerID) }
        listenerID = nil
        reloadTask?.cancel()
        reloadTask = nil
    }

    /// 第 `index` 行的行号(歌曲)或键(专辑、艺人)。
    func rowid(at index: Int) -> Int32? {
        _ = listGeneration
        return rows.ids.indices.contains(index) ? rows.ids[index] : nil
    }

    /// 第 `index` 行的内容;还没取到时返回 nil(占位),并排期取那一页。
    func item(at index: Int) -> Query.Item? {
        _ = loadedGeneration
        guard rows.ids.indices.contains(index) else { return nil }
        if let item = loaded[rows.ids[index]] {
            if abs(index - focusIndex) > pageSize / 2 { prefetch(around: index) }
            return item
        }
        prefetch(around: index)
        return nil
    }

    /// 让 `index` 上下各 `prefetchDistance` 行物化;窗口外的已物化行丢掉。
    func prefetch(around index: Int) {
        guard !rows.ids.isEmpty else { return }
        focusIndex = min(max(0, index), rows.ids.count - 1)
        let lower = max(0, focusIndex - prefetchDistance)
        let upper = min(rows.ids.count - 1, focusIndex + prefetchDistance)
        let pages = (lower / pageSize)...(upper / pageSize)
        trimLoaded(keeping: pages)
        for page in pages where !requestedPages.contains(page) {
            loadPage(page)
        }
    }

    /// 立即重查(下拉刷新、测试)。
    func reload() async {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        await performReload(generation: reloadGeneration)
    }

    /// 等第 `index` 行所在的页物化(测试用)。
    func waitForItem(at index: Int) async -> Query.Item? {
        if let item = item(at: index) { return item }
        let page = index / pageSize
        await pageTasks[page]?.value
        return rows.ids.indices.contains(index) ? loaded[rows.ids[index]] : nil
    }

    /// 物化着的行数(窗口之外的都放掉了)。
    var materializedCount: Int { loaded.count }

    /// 物化着的那几页的内容(可见区上下各 `prefetchDistance` 行),顺序不定。
    var materializedItems: [Query.Item] { Array(loaded.values) }

    // MARK: - Private

    private func catalogDidChange(_ change: LibraryCatalogChange) {
        // 内容变了的行:物化的旧值作废(行缓存已经同步失效)。
        if !change.updatedRowids.isEmpty || !change.deletedRowids.isEmpty || change.invalidatesEverything {
            if change.invalidatesEverything {
                loaded.removeAll()
            } else {
                for rowid in change.updatedRowids { loaded.removeValue(forKey: rowid) }
                for rowid in change.deletedRowids { loaded.removeValue(forKey: rowid) }
            }
            requestedPages.removeAll()
        }
        guard query.isAffected(by: change) else {
            if requestedPages.isEmpty { prefetch(around: focusIndex) }
            return
        }
        scheduleReload(after: debounce)
    }

    private func scheduleReload(after delay: Duration) {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        reloadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.performReload(generation: generation)
        }
    }

    private func performReload(generation: UInt64) async {
        let query = query
        do {
            let next = try await reader.read { try query.fetchRows($0) }
            guard generation == reloadGeneration else { return }
            apply(next)
            lastError = nil
        } catch {
            guard generation == reloadGeneration else { return }
            lastError = String(describing: error)
            isLoading = false
        }
    }

    private func apply(_ next: LibraryListRows) {
        var sameAggregates = next
        sameAggregates.aggregates = rows.aggregates
        let changed = sameAggregates != rows
        rows = next
        if aggregates != next.aggregates { aggregates = next.aggregates }
        if changed {
            let present = Set(next.ids)
            loaded = loaded.filter { present.contains($0.key) }
            requestedPages.removeAll()
            count = next.ids.count
            sections = next.sections
            browseSections = next.browseSections
            listGeneration &+= 1
        }
        isLoading = false
        prefetch(around: focusIndex)
    }

    private func loadPage(_ page: Int) {
        requestedPages.insert(page)
        let start = page * pageSize
        let end = min(rows.ids.count, start + pageSize)
        guard start < end else { return }
        let ids = Array(rows.ids[start..<end]).filter { loaded[$0] == nil }
        guard !ids.isEmpty else { return }
        let listGeneration = self.listGeneration
        let query = query
        let cache = reader.rowCache
        pageTasks[page] = Task { [weak self, reader] in
            let items = try? await reader.read { try query.materialize(ids, catalog: $0, rowCache: cache) }
            guard let self else { return }
            self.pageTasks[page] = nil
            guard listGeneration == self.listGeneration, let items else {
                self.requestedPages.remove(page)
                return
            }
            for (rowid, item) in items { self.loaded[rowid] = item }
            self.loadedGeneration &+= 1
        }
    }

    private func trimLoaded(keeping pages: ClosedRange<Int>) {
        let budget = (pages.count + 2) * pageSize
        guard loaded.count > budget else { return }
        let lower = max(0, (pages.lowerBound - 1) * pageSize)
        let upper = min(rows.ids.count, (pages.upperBound + 2) * pageSize)
        let keep = Set(rows.ids[lower..<upper])
        loaded = loaded.filter { keep.contains($0.key) }
        requestedPages = requestedPages.filter { $0 >= pages.lowerBound - 1 && $0 <= pages.upperBound + 1 }
    }
}
