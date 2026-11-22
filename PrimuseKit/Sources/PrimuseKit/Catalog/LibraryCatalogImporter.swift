import Foundation
import GRDB

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
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Primuse catalog import source"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
        let store = try DatabaseQueue(path: storePath, configuration: configuration)
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

        var batches = 0
        while true {
            if isCancelled() { throw LibraryCatalogError.cancelled }
            if let maximumBatches, batches >= maximumBatches {
                return LibraryCatalogImportProgress(imported: imported, total: total, isComplete: false)
            }
            let rows: [(orderKey: Int64, id: String, payload: Data)] = try store.read { db in
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
            guard let last = rows.last else { break }
            let songs = try IncrementalSongStore.decodeSongs(rows.map(\.payload))
            let nextCount = imported + rows.count
            try catalog.pool.write { db in
                var context = try SongWriteContext(db: db)
                context.recordsChanges = false
                for (index, prepared) in try context.prepareNew(songs).enumerated() {
                    _ = try context.insertPrepared(prepared, orderKey: rows[index].orderKey)
                }
                try LibraryCatalog.setMeta(Key.importCursorOrderKey, String(last.orderKey), in: db)
                try LibraryCatalog.setMeta(Key.importCursorID, last.id, in: db)
                try LibraryCatalog.setMeta(Key.importedCount, String(nextCount), in: db)
            }
            cursor = (last.orderKey, last.id)
            imported = nextCount
            batches += 1
            progress?(LibraryCatalogImportProgress(imported: imported, total: total, isComplete: false))
            if rows.count < batchSize { break }
        }

        try catalog.pool.write { db in
            try LibraryCatalogSchema.createDeferredIndexes(db)
            try LibraryCatalog.setMeta(Key.sortIndexesDeferred, "0", in: db)
            try LibraryCatalog.setMeta(Key.importState, "complete", in: db)
            try LibraryCatalog.bumpRevision(in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
        let result = LibraryCatalogImportProgress(imported: imported, total: total, isComplete: true)
        progress?(result)
        return result
    }
}

extension LibraryCatalog {
    /// 批量追加一批确定不在目录里的新歌(合成规模库、首次迁移)。不记变更流水。
    /// 先 `beginBulkLoad()` 拆掉排序索引,全部写完再 `finishBulkLoad()` 一次建好。
    public func bulkInsert(_ songs: [Song]) throws {
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            context.recordsChanges = false
            var orderKey = (try Int64.fetchOne(db, sql: "SELECT max(orderKey) FROM song") ?? -1) + 1
            for prepared in try context.prepareNew(songs) {
                _ = try context.insertPrepared(prepared, orderKey: orderKey)
                orderKey += 1
            }
        }
    }

    public func beginBulkLoad() throws {
        try pool.write { db in
            try LibraryCatalogSchema.dropDeferredIndexes(db)
            try Self.setMeta(MetaKey.sortIndexesDeferred, "1", in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryCatalogSchema.bulkLoadCacheKiB)")
        }
    }

    public func finishBulkLoad() throws {
        try pool.write { db in
            try LibraryCatalogSchema.createDeferredIndexes(db)
            try Self.setMeta(MetaKey.sortIndexesDeferred, "0", in: db)
            try Self.bumpRevision(in: db)
            try db.execute(sql: "PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB)")
        }
    }

    static func clearSongs(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM song;
            DELETE FROM songStat;
            DELETE FROM songOffline;
            DELETE FROM songMaintenance;
            DELETE FROM catalogChange;
            UPDATE playlistEntry SET songRowid = NULL;
            UPDATE likedSong SET songRowid = NULL;
            UPDATE dislikedSong SET songRowid = NULL;
            """)
    }
}
