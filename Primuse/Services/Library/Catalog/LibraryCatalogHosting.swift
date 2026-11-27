import Foundation
import PrimuseKit

/// `MusicLibrary` 要不要带曲库目录。
enum LibraryCatalogMirroring: Sendable, Equatable {
    /// App 自己的存储目录带,测试注入的临时目录不带。
    case automatic
    case enabled(startDelay: Duration)
    case disabled

    static let defaultStartDelay: Duration = .seconds(3)
}

/// 目录的持有方(`MusicLibrary`):后台工作此刻能不能做、目录可读状态变了。
@MainActor
protocol LibraryCatalogOwner: AnyObject {
    /// 整库的活(迁移、对账、整库重建)此刻能不能做。
    func catalogWorkAllowed() -> Bool
    /// 增量写入此刻要不要为用户的滑动让一让(只看滑动)。
    func catalogIncrementalApplyAllowed() -> Bool
    func catalogReadabilityDidChange(_ readable: Bool)
}

/// 镜像在后台线程上经它问主线程。持有方释放后一律回答「不能做」。
@MainActor
final class LibraryCatalogOwnerLink {
    weak var owner: (any LibraryCatalogOwner)?

    nonisolated init() {}

    func workAllowed() -> Bool {
        owner?.catalogWorkAllowed() ?? false
    }

    func incrementalApplyAllowed() -> Bool {
        owner?.catalogIncrementalApplyAllowed() ?? true
    }

    func readabilityDidChange(_ readable: Bool) {
        owner?.catalogReadabilityDidChange(readable)
    }
}

/// 一个 `MusicLibrary` 的目录全套:后台镜像、读接口、可观察修订号。
@MainActor
final class LibraryCatalogHost {
    let mirror: LibraryCatalogMirror
    let reader: LibraryCatalogReader
    let revisions: LibraryCatalogRevisions
    let link: LibraryCatalogOwnerLink
    /// 内存模型写进旧库、目录还没跟上的改动(按 id 读目录时先看这里)。
    let pendingWrites: LibraryPendingSongWrites
    private let relay: LibraryCatalogEventRelay
    #if DEBUG
    /// 测试、量时间:启动时按旧库的变更流水追的行数上限(0:一律整库对账,量没有流水时的开销)。
    static var journalCatchUpMaximumRowsForTesting: Int?
    #endif

    init(directory: URL, startDelay: Duration, log: @escaping @Sendable (String) -> Void) {
        let link = LibraryCatalogOwnerLink()
        let revisions = LibraryCatalogRevisions()
        let rowCache = LibraryRowCache()
        let pendingWrites = LibraryPendingSongWrites()
        let relay = LibraryCatalogEventRelay(rowCache: rowCache, revisions: revisions, pendingWrites: pendingWrites) { readable in
            link.readabilityDidChange(readable)
        }
        var environment = LibraryCatalogMirrorEnvironment(
            catalogURL: directory.appendingPathComponent("library-catalog.sqlite"),
            storeURL: directory.appendingPathComponent("library-songs.sqlite")
        )
        environment.startDelay = startDelay
        environment.resumeDelay = min(startDelay, .seconds(1))
        environment.log = log
        environment.interactionGate = { await link.workAllowed() }
        environment.incrementalApplyGate = { await link.incrementalApplyAllowed() }
        #if DEBUG
        if let rows = Self.journalCatchUpMaximumRowsForTesting { environment.journalCatchUpMaximumRows = rows }
        #endif
        let mirror = LibraryCatalogMirror(environment: environment) { relay.handle($0) }
        self.mirror = mirror
        self.reader = LibraryCatalogReader(catalog: { [weak mirror] in mirror?.readableCatalog }, rowCache: rowCache)
        self.revisions = revisions
        self.link = link
        self.pendingWrites = pendingWrites
        self.relay = relay
    }

    /// 能按 id 从目录读出与内存模型此刻相同的歌时给出读法:目录已经跟上旧库、在跟写、没有等着跟上的整份替换。
    ///
    /// 不变量在这里把关:答案只从 `mirror.caughtUpCatalog` 出 —— 目录落后旧库(刚打开还没按流水追上、
    /// 正在整库对账或导入)时它是 nil,这里就是 nil,调用方照内存模型没装好的答法,不会读到旧值。
    /// 持有方发布之前(`readableCatalog` 还不给列表读者)也能有:目录提前启动、追上了就行。
    func songLookup() -> LibraryCatalogSongLookup? {
        guard pendingWrites.answersLikeMemory, let catalog = mirror.caughtUpCatalog else { return nil }
        return LibraryCatalogSongLookup(catalog: catalog, pendingWrites: pendingWrites, rowCache: reader.rowCache)
    }

    /// 持有方还在装内存模型时启动目录(`LibraryCatalogMirror.start(beforeOwnerIsReady:)`):发布之前
    /// `readableCatalog`、`revisions` 都与目录没启动时一样,只有 `songLookup()` 在目录追上旧库之后答得出。
    func start(beforeOwnerIsReady early: LibraryCatalogMirrorEarlyStart) {
        relay.holdChangesUntilOwnerIsReady()
        mirror.start(beforeOwnerIsReady: early)
    }

    /// 提前启动的目录:持有方发布了(正式输入已经交给 `mirror.updateInputs`)。
    func ownerBecameReady() {
        relay.ownerBecameReady()
        mirror.ownerBecameReady()
    }

    /// 持有方发布、旧库的句柄有了:目录确认镜像到的修订号从此告诉旧库(剪变更流水)。
    func attachStore(_ store: IncrementalSongStore) {
        relay.attachStore(store)
    }

    /// 一个绑在这个目录上的歌曲列表模型。
    func songList(_ content: LibrarySongListQuery.Content) -> LibraryListModel<LibrarySongListQuery> {
        LibraryListModel(query: LibrarySongListQuery(content), reader: reader, revisions: revisions)
    }

    func albumList(visibleOnly: Bool = true) -> LibraryListModel<LibraryAlbumListQuery> {
        LibraryListModel(query: LibraryAlbumListQuery(visibleOnly: visibleOnly), reader: reader, revisions: revisions)
    }

    func artistList(visibleOnly: Bool = true) -> LibraryListModel<LibraryArtistListQuery> {
        LibraryListModel(query: LibraryArtistListQuery(visibleOnly: visibleOnly), reader: reader, revisions: revisions)
    }
}

/// 按 id 读目录(还在路上的改动先看待写登记,再看行缓存,最后才查目录),与内存模型 `storedSong(id:)` 的答案
/// 相同(含停用源)。可以带到主线程外用;途中目录不能再这样答时抛 `unavailable`,调用方改读内存模型。
struct LibraryCatalogSongLookup: Sendable {
    let catalog: LibraryCatalog
    let pendingWrites: LibraryPendingSongWrites
    /// 目录这一边读过的行:与列表页共用的那份有界缓存,目录每次提交后按行号失效。
    let rowCache: LibraryRowCache

    func song(id: String) throws -> Song? {
        guard pendingWrites.answersLikeMemory else { throw LibraryCatalogReaderError.unavailable }
        return try pendingWrites.resolve(id) { try rowCache.song(id: $0, in: catalog) }
    }

    /// 按 id 取一批,与输入一一对应(没有的位置为 nil)。目录那一边一次查回来,不是一首一查。
    /// 结果的大小由调用方给的 id 决定(一张歌单的全部成员);这里分批读,每批不超过物化上限。
    func songs(ids: [String]) throws -> [Song?] {
        guard pendingWrites.answersLikeMemory else { throw LibraryCatalogReaderError.unavailable }
        // 由改名而来的 id 要连旧 id 那一行一起查,一批按一半算。
        let batchSize = LibraryScale.maxMaterializedRows / 2
        guard ids.count > batchSize else { return try resolve(ids) }
        var result: [Song?] = []
        result.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            let end = min(ids.count, start + batchSize)
            result.append(contentsOf: try resolve(Array(ids[start..<end])))
            start = end
        }
        return result
    }

    /// 按音乐源数存着的歌(含停用源),还在路上的改动算在内;`removedIDs` 里的当作已经删掉。
    /// 目录的数是它最近一次提交的:路上写入的新行加上,路上删掉而目录里还在的行扣掉,换了源的行挪过去。
    /// 要补算的 id 以在路上的批为界(加上 `removedIDs`),只为它们读目录里的行。
    func songCountsBySource(treatingAsRemoved removedIDs: Set<String> = []) throws -> [String: Int] {
        guard pendingWrites.answersLikeMemory else { throw LibraryCatalogReaderError.unavailable }
        var counts = try catalog.songCountsBySource(.everything)
        let pending = pendingWrites.pendingLookups()
        var ids = Set(pending.keys).union(removedIDs)
        for case .renamed(let oldID) in pending.values { ids.insert(oldID) }
        guard !ids.isEmpty else { return counts }
        // 这些 id 在目录里此刻算在哪个源头上。
        var catalogSource: [String: String] = [:]
        let asked = Array(ids)
        var start = 0
        while start < asked.count {
            let end = min(asked.count, start + LibraryScale.maxMaterializedRows)
            for song in try catalog.songs(ids: Array(asked[start..<end])) { catalogSource[song.id] = song.sourceID }
            start = end
        }
        for id in ids {
            let before = catalogSource[id]
            let after: String?
            if removedIDs.contains(id) {
                after = nil
            } else {
                switch pending[id] {
                case .present(let song)?: after = song.sourceID
                case .deleted?: after = nil
                // 目录还没改名时这一行还在旧 id 上;已经改了就在新 id 上。
                case .renamed(let oldID)?: after = catalogSource[oldID] ?? before
                case .unknown?, nil: after = before
                }
            }
            guard before != after else { continue }
            if let before { counts[before, default: 0] -= 1 }
            if let after { counts[after, default: 0] += 1 }
        }
        return counts
    }

    /// 标题满足 `matches` 的歌(含停用源),库内顺序;路上改过的换成路上的那一版,路上删掉的不给,
    /// 路上新写入而目录还没有的补在后面。只读标题一列来筛,命中的才物化。
    /// 命中超过 `limit` 时为 nil:候选不全,不能拿来做匹配。
    func songs(
        titleMatching matches: (String) -> Bool, limit: Int = LibraryScale.maxMaterializedRows
    ) throws -> [Song]? {
        guard pendingWrites.answersLikeMemory else { throw LibraryCatalogReaderError.unavailable }
        var rowids: [Int32] = []
        var overflowed = false
        try catalog.forEachSongTitle(.everything) { rowid, title in
            guard matches(title) else { return true }
            guard rowids.count < limit else {
                overflowed = true
                return false
            }
            rowids.append(rowid)
            return true
        }
        guard !overflowed else { return nil }
        let committed = try catalog.songs(rowids: rowids)
        let pending = pendingWrites.pendingLookups()
        guard !pending.isEmpty else { return committed }
        var result: [Song] = []
        var included = Set<String>()
        for song in committed {
            switch pending[song.id] {
            case .present(let current)?:
                included.insert(song.id)
                if matches(current.title) { result.append(current) }
            case .deleted?:
                continue
            case .renamed?, .unknown?, nil:
                included.insert(song.id)
                result.append(song)
            }
        }
        let late = pending.values.compactMap { state -> Song? in
            guard case .present(let song) = state, !included.contains(song.id), matches(song.title) else { return nil }
            return song
        }.sorted { $0.id < $1.id }
        return result + late
    }

    /// 同 `LibraryPendingSongWrites.resolve`,一批一起做。
    private func resolve(_ ids: [String]) throws -> [Song?] {
        guard let pending = pendingWrites.lookups(ids) else { return try rowCache.songs(ids: ids, in: catalog) }
        var catalogIDs: [String] = []
        for (offset, state) in pending.enumerated() {
            switch state {
            case .unknown:
                catalogIDs.append(ids[offset])
            case .renamed(let oldID):
                catalogIDs.append(oldID)
                catalogIDs.append(ids[offset])
            case .present, .deleted:
                break
            }
        }
        let fetched = try rowCache.songs(ids: catalogIDs, in: catalog)
        var catalogSongs: [String: Song] = [:]
        for (id, song) in zip(catalogIDs, fetched) {
            if let song { catalogSongs[id] = song }
        }
        return pending.enumerated().map { offset, state in
            switch state {
            case .unknown:
                return catalogSongs[ids[offset]]
            case .present(let song):
                return song
            case .deleted:
                return nil
            case .renamed(let oldID):
                // 目录还没改名时读旧 id 那一行换上新 id,已经改了就读新 id。
                guard var moved = catalogSongs[oldID] else { return catalogSongs[ids[offset]] }
                moved.id = ids[offset]
                return moved
            }
        }
    }
}
