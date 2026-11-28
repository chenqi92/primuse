import Foundation
import GRDB
import SQLite3
import os

/// 迁移各阶段累计耗时(按批计时,不按行),规模测试与诊断日志用。
public enum LibraryCatalogImportProfile {
    private static let state = OSAllocatedUnfairLock(initialState: [String: Double]())

    public static func reset() { state.withLock { $0.removeAll() } }

    @discardableResult
    static func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            state.withLock { $0[stage, default: 0] += elapsed }
        }
        return try body()
    }

    /// "阶段=毫秒" 按耗时从大到小。
    public static func summary() -> String {
        state.withLock { $0 }.sorted { $0.value > $1.value }
            .map { "\($0.key)=\(Int($0.value * 1_000))ms" }.joined(separator: " ")
    }
}

public struct LibraryCatalogImportProgress: Sendable, Equatable {
    public let imported: Int
    public let total: Int
    public let isComplete: Bool
}

/// 从现有的 `library-songs.sqlite`(`IncrementalSongStore`,表 `librarySongRecords`,
/// 每行一份 JSON)流式导入目录。
///
/// - 每批 `batchSize` 行在一个写事务里落库,同一事务记下游标(`orderKey`, `id`),
///   被杀后从断点继续;内存只占一批。
/// - 库内顺序照搬 `orderKey`,与 `IncrementalSongStore.loadSongs()` 的顺序一致。
/// - 开始时拆掉排序索引,导完一次建好(走排序器,比逐行维护快得多)。
/// - 续导时旧库的内容修订号变了(中途又写过)就从头再来。
public enum LibraryCatalogImporter {
    public static func importIncrementalSongStore(
        at storePath: String,
        into catalog: LibraryCatalog,
        batchSize: Int = LibraryScale.importBatchSize,
        maximumBatches: Int? = nil,
        progress: ((LibraryCatalogImportProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> LibraryCatalogImportProgress {
        let configuration = catalog.groupingConfiguration
        var storeConfiguration = Configuration()
        storeConfiguration.readonly = true
        storeConfiguration.label = "Primuse catalog import source"
        storeConfiguration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
        let store = try DatabaseQueue(path: storePath, configuration: storeConfiguration)
        let storeState = try IncrementalSongPageReader.startupState(at: storePath)
        let total = try store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM librarySongRecords") ?? 0
        }

        typealias Key = LibraryCatalog.MetaKey
        var cursor: (orderKey: Int64, id: String)?
        var imported = 0
        let alreadyComplete: Bool = try catalog.pool.write { db in
            let state = try LibraryCatalog.metaValue(Key.importState, in: db)
            if state == "complete" { return true }
            let storedRevision = try LibraryCatalog.metaValue(Key.importStoreRevision, in: db).flatMap(Int64.init)
            if state == "running", storedRevision == storeState.contentRevision {
                if let orderKey = try LibraryCatalog.metaValue(Key.importCursorOrderKey, in: db).flatMap(Int64.init),
                   let id = try LibraryCatalog.metaValue(Key.importCursorID, in: db) {
                    cursor = (orderKey, id)
                }
                imported = try LibraryCatalog.metaValue(Key.importedCount, in: db).flatMap(Int.init) ?? 0
            } else {
                // 第一次导入,或旧库在两次之间变过:目录里的歌全部重来。
                try LibraryCatalog.clearSongs(in: db)
                try LibraryCatalog.setMeta(Key.importState, "running", in: db)
                try LibraryCatalog.setMeta(Key.importStoreRevision, String(storeState.contentRevision), in: db)
                try LibraryCatalog.removeMeta(Key.importCursorOrderKey, in: db)
                try LibraryCatalog.removeMeta(Key.importCursorID, in: db)
                try LibraryCatalog.setMeta(Key.importedCount, "0", in: db)
            }
            try LibraryCatalogSchema.dropDeferredIndexes(db)
            try LibraryCatalog.setMeta(Key.sortIndexesDeferred, "1", in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryCatalogSchema.bulkLoadCacheKiB)")
            return false
        }
        if alreadyComplete {
            return LibraryCatalogImportProgress(imported: total, total: total, isComplete: true)
        }

        // 逐批导入放在单独的作用域里:引用缓存、解析缓存与预备线程的那一批在建索引前就放掉。
        do {
            // 艺人 id、流派、文件夹路径的整数引用与艺人解析结果跨批复用(条目数有上限)。
            let refs = CatalogRefCache()
            let memo = GroupingMaintenance.RowValueMemo()
            // 读旧库、解码与逐行派生不碰目录的写事务:下一批在另一个线程上算,与这一批落库重叠。
            // 落库仍按批、按 `orderKey` 顺序在写事务里做,游标与这批同一事务提交。
            let producer = ImportBatchProducer(store: store, catalog: catalog, configuration: configuration,
                                               memo: memo, batchSize: batchSize)
            var batches = 0
            var pending: ImportBatchProducer.Pending? = producer.start(after: cursor)
            defer { pending?.discard() }
            while true {
                if isCancelled() { throw LibraryCatalogError.cancelled }
                if let maximumBatches, batches >= maximumBatches {
                    return LibraryCatalogImportProgress(imported: imported, total: total, isComplete: false)
                }
                guard let batch = try LibraryCatalogImportProfile.measure("pipeline.wait", { try pending?.wait() }) else { break }
                pending = batch.rows.count < batchSize ? nil : producer.start(after: batch.last)
                let nextCount = imported + batch.rows.count
                try catalog.pool.write { db in
                    var context = try SongWriteContext(db: db)
                    context.recordsChanges = false
                    // 提前算的那批用的是当时读到的源特征;写事务里再核一次,变了就按现在的重算。
                    // 重算用新的 memo:共用的那个这时可能正被下一批的预备线程用着(memo 只缓存纯函数结果)。
                    let current = try SongWriteContext.sourceTraits(in: db)
                    let prepared = batch.traits.allSatisfy({ (current[$0.key] ?? .init()) == $0.value })
                        ? batch.prepared
                        : try LibraryCatalogImportProfile.measure("prepare.recheck") {
                            try context.prepare(batch.songs, configuration: configuration, memo: GroupingMaintenance.RowValueMemo())
                        }
                    var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    grouping.tracksDirty = false
                    try LibraryCatalogImportProfile.measure("insertRows") {
                        for (index, row) in prepared.enumerated() {
                            _ = try context.insertNew(row, orderKey: batch.rows[index].orderKey, grouping: &grouping)
                        }
                    }
                    try LibraryCatalog.setMeta(Key.importCursorOrderKey, String(batch.last.orderKey), in: db)
                    try LibraryCatalog.setMeta(Key.importCursorID, batch.last.id, in: db)
                    try LibraryCatalog.setMeta(Key.importedCount, String(nextCount), in: db)
                }
                cursor = batch.last
                imported = nextCount
                batches += 1
                progress?(LibraryCatalogImportProgress(imported: imported, total: total, isComplete: false))
                if batch.rows.count < batchSize { break }
            }
        }

        // 本地化排序索引留到迁移后由 `buildPendingSortIndexes` 在后台补(见 `backgroundSortIndexNames`)。
        // 其余每条一个写事务:排序器与页缓存一条一放,内存峰值不随索引条数叠加。中途被杀时导入还是
        // running,下次进来读不到新行,直接从没建的那条接着建(IF NOT EXISTS)。
        try LibraryCatalogImportProfile.measure("createIndexes") {
            for index in LibraryCatalogSchema.migrationIndexes {
                try catalog.pool.write { db in try LibraryCatalog.createIndexesProfiled(db, [index]) }
            }
        }
        try catalog.pool.write { db in
            try LibraryCatalog.setMeta(Key.sortIndexesDeferred, "0", in: db)
            try LibraryCatalog.notePendingSortIndexes(in: db)
            try LibraryCatalog.setMeta(Key.importState, "complete", in: db)
            // 逐行派生已随导入写好;跨行的分组(推断、专辑、艺人、书)由调用方随后
            // `rebuildGrouping()` 从「目录权威」阶段接着做。
            try LibraryCatalog.removeMeta(Key.groupingFingerprint, in: db)
            try LibraryCatalog.setMeta(Key.groupingRebuildPhase, "authority\u{1}\(configuration.fingerprint)", in: db)
            try LibraryCatalog.setMeta(Key.groupingRebuildCursor, "", in: db)
            try LibraryCatalog.bumpRevision(in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
        let result = LibraryCatalogImportProgress(imported: imported, total: total, isComplete: true)
        progress?(result)
        return result
    }
}

extension LibraryCatalog {
    /// 批量追加一批确定不在目录里的新歌(合成规模库、首次迁移),连同逐行分组派生。不记变更流水。
    /// 先 `beginBulkLoad()` 拆掉索引,全部写完再 `finishBulkLoad()` 一次建好,随后 `rebuildGrouping()`
    /// 从「目录权威」阶段接着做跨行的分组。
    public func bulkInsert(_ songs: [Song]) throws {
        let configuration = groupingConfiguration
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            context.recordsChanges = false
            var orderKey = (try Int64.fetchOne(db, sql: "SELECT max(orderKey) FROM song") ?? -1) + 1
            var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: bulkLoadRefs)
            grouping.tracksDirty = false
            for prepared in try context.prepare(songs.map(\.withoutAppliedPlaybackRange), configuration: configuration, memo: bulkLoadMemo) {
                _ = try context.insertNew(prepared, orderKey: orderKey, grouping: &grouping)
                orderKey += 1
            }
        }
    }

    public func beginBulkLoad() throws {
        bulkLoadRefs.forgetFolders()
        try pool.write { db in
            try LibraryCatalogSchema.dropDeferredIndexes(db)
            try Self.setMeta(MetaKey.sortIndexesDeferred, "1", in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryCatalogSchema.bulkLoadCacheKiB)")
        }
    }

    public func finishBulkLoad() throws {
        try pool.write { db in
            try Self.createIndexesProfiled(db)
            try Self.setMeta(MetaKey.sortIndexesDeferred, "0", in: db)
            try Self.notePendingSortIndexes(in: db)
            try Self.removeMeta(MetaKey.groupingFingerprint, in: db)
            try Self.setMeta(MetaKey.groupingRebuildPhase, "authority\u{1}\(groupingConfiguration.fingerprint)", in: db)
            try Self.setMeta(MetaKey.groupingRebuildCursor, "", in: db)
            try Self.bumpRevision(in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
        bulkLoadRefs.forgetFolders()
        bulkLoadRefs.forgetAlbums()
    }

    /// 建延后的索引(默认全部),每条单独计时(`createIndexes.<名字>`)。
    static func createIndexesProfiled(
        _ db: Database,
        _ indexes: [(name: String, sql: String)] = LibraryCatalogSchema.deferredIndexes
    ) throws {
        // 建索引时用平常大小的页缓存:排序器每段的大小跟着页缓存走,用批量导入时的 32 MiB 建,
        // 50 万首建完 footprint 多出两百多 MiB 不回落(4 MiB 时约 40 MiB,只慢约 1 s)。
        let cacheSize = try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? -LibraryScale.connectionCacheKiB
        try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        defer { try? db.execute(sql: "PRAGMA cache_size = \(cacheSize)") }
        // 批量写入时攒下的页缓存先还掉,再开始排序。
        sqlite3_db_release_memory(db.sqliteConnection)
        for index in indexes {
            try LibraryCatalogImportProfile.measure("createIndexes.\(index.name)") { try db.execute(sql: index.sql) }
        }
    }

    /// 留到后台的排序索引有没建的就记成待建,都在就清掉标记。
    static func notePendingSortIndexes(in db: Database) throws {
        let existing = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        if LibraryCatalogSchema.backgroundSortIndexNames.isSubset(of: existing) {
            try removeMeta(MetaKey.sortIndexesPending, in: db)
        } else {
            try setMeta(MetaKey.sortIndexesPending, "1", in: db)
        }
    }

    /// 迁移后还有没建的排序索引(艺人、专辑、文件名)。没建好之前这几种排序要整表排序。
    public func hasPendingSortIndexes() throws -> Bool {
        try pool.read { db in try Self.metaValue(MetaKey.sortIndexesPending, in: db) == "1" }
    }

    /// 补建迁移时留到后台的排序索引。每条一个写事务:被杀或取消后,下次从没建的那条接着建;
    /// 建一条时写连接被占着(10 万首约 0.8 s,50 万首约 4–5 s)。导入或批量写入还没收尾时不建,返回 false。
    /// 全部建好返回 true。索引内容与迁移时一起建的完全一样,不改排序结果、不改修订号。
    @discardableResult
    public func buildPendingSortIndexes(isCancelled: () -> Bool = { false }) throws -> Bool {
        for index in LibraryCatalogSchema.backgroundSortIndexes {
            if isCancelled() { return false }
            let built: Bool = try pool.write { db in
                guard try Self.metaValue(MetaKey.importState, in: db) != "running",
                      try Self.metaValue(MetaKey.sortIndexesDeferred, in: db) != "1" else { return false }
                // 用连接平常的页缓存建(见 `createIndexesProfiled`:页缓存大了内存峰值随曲库变大)。
                try LibraryCatalogImportProfile.measure("sortIndexes.\(index.name)") { try db.execute(sql: index.sql) }
                return true
            }
            guard built else { return false }
        }
        try pool.write { db in try Self.notePendingSortIndexes(in: db) }
        return true
    }

    /// 从 v3 升上来、专辑的发行类别还欠补算(`backfillReleaseCategories`)。
    public func hasPendingReleaseCategoryBackfill() throws -> Bool {
        try pool.read { db in
            if case .backfill = ReleaseCategoryState(metaValue: try Self.metaValue(MetaKey.releaseCategories, in: db)) { return true }
            return false
        }
    }

    /// 补算升级之前就在的专辑的发行类别:按专辑键从小到大,每批 `batchSize` 张一个写事务(只改发行类别那两列,
    /// 不动别的聚合、不改修订号),批与批之间问 `isCancelled`。游标记在 meta 里:被杀、被叫停之后下次从没补的
    /// 那张接着补。补完记「算齐了」。补的同时照常写进来的专辑由增量维护连同发行类别一起写,不受影响。
    /// 导入或整库重建还没做完时不补(整库重建做完时本来就算齐了),返回 false。补完返回 true。
    @discardableResult
    public func backfillReleaseCategories(batchSize: Int = 500, isCancelled: () -> Bool = { false }) throws -> Bool {
        while true {
            if isCancelled() { return false }
            let finished: Bool? = try pool.write { db in
                guard case .backfill(let after) = ReleaseCategoryState(
                    metaValue: try Self.metaValue(MetaKey.releaseCategories, in: db)
                ) else { return true }
                guard try Self.metaValue(MetaKey.importState, in: db) != "running",
                      try Self.metaValue(MetaKey.groupingRebuildPhase, in: db) == nil else { return nil }
                let albums = try Row.fetchAll(
                    db, sql: "SELECT key, title FROM album WHERE key > ? ORDER BY key LIMIT ?", arguments: [after, batchSize]
                )
                guard let last = albums.last else {
                    try Self.setMeta(MetaKey.releaseCategories, ReleaseCategoryState.complete.metaValue, in: db)
                    return true
                }
                var grouping = GroupingMaintenance(db: db, configuration: groupingConfiguration)
                for album in albums { try grouping.refreshReleaseCategories(albumKey: album[0], title: album[1]) }
                try Self.setMeta(MetaKey.releaseCategories, ReleaseCategoryState.backfill(after: last[0]).metaValue, in: db)
                return false
            }
            guard let finished else { return false }
            if finished { return true }
        }
    }

    #if DEBUG
    /// 测试与规模测试:把目录弄成「刚从 v3 升上来」的样子(发行类别两列清零、记「待补算」),量升级后第一次补算。
    public func simulateReleaseCategoryUpgradeForTesting() throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE album SET releaseTitleFlags = 0; UPDATE albumSourceStat SET releaseFlags = 0")
            try Self.setMeta(MetaKey.releaseCategories, ReleaseCategoryState.backfill(after: 0).metaValue, in: db)
        }
    }
    #endif

    static func clearSongs(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM song;
            DELETE FROM songStat;
            DELETE FROM songOffline;
            DELETE FROM catalogChange;
            DELETE FROM songArtist; DELETE FROM songArtistLookup; DELETE FROM songGenre; DELETE FROM songBook;
            DELETE FROM folder; DELETE FROM album; DELETE FROM albumSourceStat; DELETE FROM albumArtistCredit;
            DELETE FROM artist; DELETE FROM artistSourceStat; DELETE FROM book; DELETE FROM artistRef; DELETE FROM genreName;
            DROP TABLE IF EXISTS groupingAlbumAssignment;
            UPDATE playlistEntry SET songRowid = NULL;
            UPDATE likedSong SET songRowid = NULL;
            UPDATE dislikedSong SET songRowid = NULL;
            """)
    }
}

/// 导入的下一批:读旧库一页、解码、按当时的源特征逐行派生(都不碰目录的写事务)。
struct ImportBatch: @unchecked Sendable {
    let rows: [(orderKey: Int64, id: String)]
    let songs: [Song]
    let traits: [String: LibraryCatalogDerivedFields.SourceTraits]
    let prepared: [SongWriteContext.PreparedRow]
    var last: (orderKey: Int64, id: String) { rows[rows.count - 1] }
}

/// 在另一个线程上算导入的下一批。同一时间只算一批(`memo` 只有一个使用方);
/// 线程的服务质量跟调用方一样。
struct ImportBatchProducer: @unchecked Sendable {
    let store: DatabaseQueue
    let catalog: LibraryCatalog
    let configuration: LibraryGroupingConfiguration
    let memo: GroupingMaintenance.RowValueMemo
    let batchSize: Int

    final class Pending: @unchecked Sendable {
        private let group = DispatchGroup()
        private var result: Result<ImportBatch?, Error> = .success(nil)

        fileprivate init(_ work: @escaping @Sendable () throws -> ImportBatch?) {
            let qos = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .utility
            group.enter()
            DispatchQueue.global(qos: qos).async { [self] in
                result = Result { try work() }
                group.leave()
            }
        }

        func wait() throws -> ImportBatch? {
            group.wait()
            return try result.get()
        }

        /// 提前结束(出错、取消、到了批数上限)时等它算完,不留在后台的读。
        func discard() { group.wait() }
    }

    func start(after cursor: (orderKey: Int64, id: String)?) -> Pending {
        let producer = self
        return Pending { try producer.produce(after: cursor) }
    }

    func produce(after cursor: (orderKey: Int64, id: String)?) throws -> ImportBatch? {
        let records: [(orderKey: Int64, id: String, payload: Data)] = try LibraryCatalogImportProfile.measure("read") {
            try store.read { db in
                let sql: String
                let arguments: StatementArguments
                if let cursor {
                    sql = """
                        SELECT orderKey, id, payload FROM librarySongRecords
                        WHERE (orderKey, id) > (?, ?) ORDER BY orderKey, id LIMIT ?
                        """
                    arguments = [cursor.orderKey, cursor.id, batchSize]
                } else {
                    sql = "SELECT orderKey, id, payload FROM librarySongRecords ORDER BY orderKey, id LIMIT ?"
                    arguments = [batchSize]
                }
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map { ($0[0], $0[1], $0[2]) }
            }
        }
        guard !records.isEmpty else { return nil }
        let songs = try LibraryCatalogImportProfile.measure("decodeJSON") {
            try IncrementalSongStore.decodeSongs(records.map(\.payload)).map(\.withoutAppliedPlaybackRange)
        }
        let known = try catalog.pool.read { try SongWriteContext.sourceTraits(in: $0) }
        var traits: [String: LibraryCatalogDerivedFields.SourceTraits] = [:]
        for song in songs where traits[song.sourceID] == nil {
            traits[song.sourceID] = known[song.sourceID] ?? .init()
        }
        let prepared = LibraryCatalogImportProfile.measure("prepare") {
            SongWriteContext.prepareRows(songs, traits: traits, configuration: configuration, memo: memo)
        }
        return ImportBatch(rows: records.map { ($0.orderKey, $0.id) }, songs: songs, traits: traits, prepared: prepared)
    }
}

// MARK: - Catching up from the store's change journal

/// 旧库(`library-songs.sqlite`)一个修订号里做过的事,换成曲库目录的一次写入:
/// 先改名,再删,最后写入(`upserts` 按库内顺序,新行就按这个先后追加)。
public struct IncrementalSongStoreChangeBatch: Sendable {
    public let storeRevision: Int64
    public let renaming: [String: String]
    public let deletingIDs: [String]
    // crash-pattern: allow library-array-property 一个修订号改的行,不超过调用方给的 maximumRowsPerRevision(镜像给 4,096);用完即弃
    public let upserts: [Song]

    public var rowCount: Int { renaming.count + deletingIDs.count + upserts.count }
}

public enum IncrementalSongStoreChangeReplay: Equatable, Sendable {
    /// 流水接得上:`storeRevision` 是读的那一刻旧库的修订号,这之前每个有改动的修订号都交给过调用方。
    /// `songCount` 是同一刻旧库里的行数(调用方拿它核对重放完的目录)。
    case replayed(storeRevision: Int64, revisions: Int, rows: Int, songCount: Int)
    /// 流水接不上,调用方整库对账。附原因(记日志用)。
    case unavailable(String)
}

extension IncrementalSongStoreScanner {
    /// 曲库目录停在旧库的修订号 `mirroredRevision`:把这之后旧库做过的改动按修订号的先后重放给 `body`,
    /// 每个修订号一批(调用方要把一批连同「镜像到这个修订号」一起原子地写进目录,重放才不怕中途被杀)。
    ///
    /// 流水只记 id。写入的内容取旧库里这一行此刻的样子:同一行后来又改过时拿到的是更新的那一份,
    /// 后面的批次还会再写一遍,结果相同;这一行后来改了名就按新名字取、换回当时的 id(下一批里的改名
    /// 再把它改过去,行号不变);后来删掉了的不写(轮到那一批时目录里本来也没有它)。
    ///
    /// 整个重放在旧库的一个读事务里:期间旧库照常能写,读到的始终是开始那一刻的样子。
    ///
    /// - Parameters:
    ///   - maximumRows: 流水里的记录超过这么多就不重放(整库对账更快)。
    ///   - maximumRowsPerRevision: 一个修订号改的行超过这么多也不重放(一批要在目录的一个事务里写完)。
    public func replayChanges(
        after mirroredRevision: Int64,
        maximumRows: Int,
        maximumRowsPerRevision: Int,
        _ body: (IncrementalSongStoreChangeBatch) throws -> Void
    ) throws -> IncrementalSongStoreChangeReplay {
        try database.read { db in
            let journal = IncrementalSongStore.ChangeJournal.self
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: [journal.table]
            ) == true else { return .unavailable("the store has no change journal yet") }
            func metadata(_ key: String) throws -> Int64? {
                try Int64.fetchOne(
                    db, sql: "SELECT CAST(value AS INTEGER) FROM libraryStoreMetadata WHERE key = ?", arguments: [key]
                )
            }
            guard let floor = try metadata(journal.floorKey) else { return .unavailable("the journal has no starting point") }
            let storeRevision = try metadata("songs-content-revision") ?? 0
            guard mirroredRevision >= floor else {
                return .unavailable("the journal starts at revision \(floor), after the mirrored revision \(mirroredRevision)")
            }
            guard mirroredRevision <= storeRevision else {
                return .unavailable("the mirrored revision \(mirroredRevision) is ahead of the store's \(storeRevision)")
            }

            let entryCount = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM \(journal.table) WHERE revision > ?", arguments: [mirroredRevision]
            ) ?? 0
            guard entryCount <= maximumRows else {
                return .unavailable("\(entryCount) journal rows, more than \(maximumRows)")
            }
            var entries: [StoreChangeJournalEntry] = []
            entries.reserveCapacity(entryCount)
            let rows = try Row.fetchCursor(
                db, sql: "SELECT revision, kind, id, newID FROM \(journal.table) WHERE revision > ? ORDER BY sequence",
                arguments: [mirroredRevision]
            )
            while let row = try rows.next() {
                guard let kind = IncrementalSongStore.ChangeJournal.Kind(rawValue: row[1]) else {
                    return .unavailable("an unknown journal entry kind")
                }
                entries.append(StoreChangeJournalEntry(revision: row[0], kind: kind, id: row[2], newID: row[3]))
            }
            guard let plan = StoreChangeReplayPlan(entries: entries, storeRevision: storeRevision) else {
                return .unavailable("journal entries out of order or past the store's revision")
            }
            // 流水要一个修订号都不缺。旧库每改一次修订号进一、同一个事务里记流水;不认识流水的旧版本
            // (降级装回去)写过的话,修订号往前走了,流水里却没有那一次。
            guard Int64(plan.revisions.count) == storeRevision - mirroredRevision,
                  plan.revisions.enumerated().allSatisfy({ $0.element.revision == mirroredRevision + Int64($0.offset) + 1 })
            else {
                return .unavailable("the journal does not cover every revision after \(mirroredRevision)")
            }
            if let large = plan.revisions.first(where: { $0.rowCount > maximumRowsPerRevision }) {
                return .unavailable("revision \(large.revision) changed \(large.rowCount) rows, more than \(maximumRowsPerRevision)")
            }

            var replayedRows = 0
            for revision in plan.revisions {
                // 这一批要写的行:按它们此刻在旧库里的名字取,库内顺序(orderKey, id)。
                var stored: [String: (orderKey: Int64, song: Song)] = [:]
                let currentIDs = Array(Set(revision.upserts.map(\.currentID)))
                for start in stride(from: 0, to: currentIDs.count, by: 500) {
                    let chunk = Array(currentIDs[start..<min(start + 500, currentIDs.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let fetched = try Row.fetchAll(
                        db, sql: "SELECT orderKey, id, payload FROM librarySongRecords WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                    let songs = try IncrementalSongStore.decodeSongs(fetched.map { $0[2] as Data })
                    guard songs.count == fetched.count else { throw LibraryCatalogError.corruptRow }
                    for (row, song) in zip(fetched, songs) { stored[row[1]] = (row[0], song) }
                }
                var upserts: [(orderKey: Int64, song: Song)] = []
                upserts.reserveCapacity(revision.upserts.count)
                for upsert in revision.upserts {
                    guard let row = stored[upsert.currentID] else {
                        return .unavailable("the store has no row \(upsert.currentID) that the journal says it wrote")
                    }
                    var song = row.song
                    if song.id != upsert.id { song.id = upsert.id }
                    upserts.append((row.orderKey, song))
                }
                upserts.sort { $0.orderKey != $1.orderKey ? $0.orderKey < $1.orderKey : $0.song.id < $1.song.id }
                let batch = IncrementalSongStoreChangeBatch(
                    storeRevision: revision.revision,
                    renaming: revision.renaming,
                    deletingIDs: revision.deletingIDs,
                    upserts: upserts.map(\.song)
                )
                try body(batch)
                replayedRows += batch.rowCount
            }
            let songCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM librarySongRecords") ?? 0
            return .replayed(
                storeRevision: storeRevision, revisions: plan.revisions.count, rows: replayedRows, songCount: songCount
            )
        }
    }
}

struct StoreChangeJournalEntry: Equatable {
    var revision: Int64
    var kind: IncrementalSongStore.ChangeJournal.Kind
    var id: String
    var newID: String?
}

/// 流水里一段记录按修订号分好的重放计划(不碰数据库,单独测)。
struct StoreChangeReplayPlan: Equatable {
    struct Upsert: Equatable {
        /// 这一批里写的是哪个 id。
        var id: String
        /// 这一行此刻在旧库里叫什么(之后改过名就是新名字)。
        var currentID: String
    }

    struct Revision: Equatable {
        var revision: Int64
        var renaming: [String: String] = [:]
        var deletingIDs: [String] = []
        var upserts: [Upsert] = []

        var rowCount: Int { renaming.count + deletingIDs.count + upserts.count }
    }

    var revisions: [Revision]

    /// `entries` 按流水的先后(修订号不降,同一个修订号里先改名、再删、最后写入)。顺序不对、
    /// 或者有修订号超过 `storeRevision` 时为 nil。
    init?(entries: [StoreChangeJournalEntry], storeRevision: Int64) {
        var previous: (revision: Int64, kind: Int) = (.min, 0)
        for entry in entries {
            guard entry.revision <= storeRevision,
                  entry.revision > previous.revision
                    || (entry.revision == previous.revision && entry.kind.rawValue >= previous.kind) else { return nil }
            if entry.kind == .rename, entry.newID == nil { return nil }
            previous = (entry.revision, entry.kind.rawValue)
        }

        // 从后往前走一遍:`fate[x]` 是「此刻叫 x 的那一行」最后的下落(改成了哪个名字;nil 是后来删掉了)。
        // 表里没有的 id 就是一直叫这个名字、一直在。
        var fate: [String: String?] = [:]
        var currentIDByEntry = [String?](repeating: nil, count: entries.count)
        for index in entries.indices.reversed() {
            let entry = entries[index]
            switch entry.kind {
            case .upsert:
                // 这一刻写下的这一行:后来叫什么。写入之前叫这个名字的行(如果有)是同一行,下落相同。
                if let known = fate[entry.id] {
                    currentIDByEntry[index] = known
                } else {
                    currentIDByEntry[index] = entry.id
                }
            case .delete:
                // 删之前叫这个名字的行到此为止。
                fate[entry.id] = .some(nil)
            case .rename:
                guard let newID = entry.newID else { return nil }
                // 改名之前叫旧名字的行,下落就是新名字那一行后来的下落;新名字在改名之前没有行。
                let after: String? = fate[newID] ?? newID
                fate[newID] = nil
                fate[entry.id] = .some(after)
            case .marker:
                break
            }
        }

        var revisions: [Revision] = []
        for (index, entry) in entries.enumerated() {
            if revisions.last?.revision != entry.revision { revisions.append(Revision(revision: entry.revision)) }
            let last = revisions.count - 1
            switch entry.kind {
            case .rename:
                if let newID = entry.newID { revisions[last].renaming[entry.id] = newID }
            case .delete:
                revisions[last].deletingIDs.append(entry.id)
            case .upsert:
                // 后来删掉了的不写;同一批里同一个 id 记了两次的只写一次。
                guard let currentID = currentIDByEntry[index],
                      !revisions[last].upserts.contains(where: { $0.id == entry.id }) else { continue }
                revisions[last].upserts.append(Upsert(id: entry.id, currentID: currentID))
            case .marker:
                // 一行都没动的修订号:占一批空的(调用方照样记下镜像到了这个修订号)。
                break
            }
        }
        self.revisions = revisions
    }
}
