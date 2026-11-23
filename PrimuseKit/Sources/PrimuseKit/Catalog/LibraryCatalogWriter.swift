import Foundation
import GRDB
import os
import SQLite3

/// 一次 `apply` 改了什么。行号与键都只给受影响的那些,观察方据此精确失效。
public struct LibraryCatalogChangeSummary: Sendable, Equatable {
    public let revision: Int64
    public let insertedRowids: ContiguousArray<Int32>
    public let updatedRowids: ContiguousArray<Int32>
    public let deletedRowids: ContiguousArray<Int32>
    /// 与库里现有行完全相同、没有写的。
    public let unchangedCount: Int

    public var isEmpty: Bool { insertedRowids.isEmpty && updatedRowids.isEmpty && deletedRowids.isEmpty }
}

enum LibraryCatalogChangeKind: Int {
    case inserted = 1
    case updated = 2
    case deleted = 3
}

extension LibraryCatalog {
    /// 在一个写事务里 upsert 与删除。已有的行保持行号与库内顺序(`orderKey`),
    /// 新行按输入顺序追加到库尾,与 `IncrementalSongStore.apply` 的顺序语义一致。
    /// 分组派生按脏范围增量维护,工作量与改动同阶(`lastWriteWork` 记着读写了多少行)。
    @discardableResult
    public func apply(upserts: [Song], deletingIDs: some Collection<String> = [String]()) throws -> LibraryCatalogChangeSummary {
        let configuration = groupingConfiguration
        let measures = measuresWriteWork
        let (summary, work) = try pool.write { db -> (LibraryCatalogChangeSummary, LibraryCatalogWriteWork) in
            let meter = measures ? CatalogWorkMeter(db) : nil
            var context = try SongWriteContext(db: db)
            var grouping = GroupingMaintenance(db: db, configuration: configuration)
            var inserted = ContiguousArray<Int32>()
            var updated = ContiguousArray<Int32>()
            var deleted = ContiguousArray<Int32>()
            var unchanged = 0
            var deletedIDs = Set<String>()

            for id in deletingIDs where deletedIDs.insert(id).inserted {
                guard let rowid = try Int64.fetchOne(
                    db.cachedStatement(sql: "SELECT rowid FROM song WHERE id = ?"), arguments: [id]
                ) else { continue }
                try grouping.noteExisting(rowid: rowid)
                try grouping.removeDerivedRows(rowid: rowid)
                try context.deleteSong(rowid: rowid, id: id)
                grouping.work.rowsWritten += 1
                deleted.append(try Self.rowid32(rowid))
            }

            let prepared = try LibraryCatalogImportProfile.measure("write.prepare") {
                try context.prepare(upserts.map(\.withoutAppliedPlaybackRange), configuration: configuration)
            }
            try LibraryCatalogImportProfile.measure("write.rows") {
                for row in prepared {
                    switch try context.upsert(row, grouping: &grouping) {
                    case .inserted(let rowid): inserted.append(try Self.rowid32(rowid))
                    case .updated(let rowid): updated.append(try Self.rowid32(rowid))
                    case .unchanged: unchanged += 1
                    }
                }
            }
            grouping.work.rowsWritten += inserted.count + updated.count
            if try Self.metaValue(MetaKey.groupingRebuildPhase, in: db) != nil {
                // 整库重建还没做完:逐行派生已随行写好,跨行的分组交给重建从「目录权威」阶段重来。
                try Self.restartRebuildAfterWrite(in: db)
            } else {
                try grouping.flush()
            }

            let revision = inserted.isEmpty && updated.isEmpty && deleted.isEmpty
                ? try Self.revision(in: db)
                : try Self.bumpRevision(in: db)
            var work = grouping.work
            work.kiloInstructions = meter?.stop() ?? 0
            return (LibraryCatalogChangeSummary(
                revision: revision,
                insertedRowids: inserted,
                updatedRowids: updated,
                deletedRowids: deleted,
                unchangedCount: unchanged
            ), work)
        }
        recordWriteWork(work)
        return summary
    }

    /// 音乐源的显示名(排序「按来源」与它的字母索引用)。nil 表示按 id 排。
    public func setSourceNames(_ names: [String: String?]) throws {
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            for (sourceID, name) in names {
                let key = try context.sourceKey(for: sourceID)
                try db.execute(sql: "UPDATE source SET name = ? WHERE key = ?", arguments: [name, key])
            }
        }
    }

    /// 播放路径里不带文件名的音乐源:文件名排序用扫描索引给的显示名,没有就用标题
    /// (与 `SongListSortValues.fileNameIndexesBySourceID` 的规则一致)。传 nil 恢复按路径取名。
    public func setFileNameIndex(sourceID: String, index: SourceSyncIndex?) throws {
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            let key = try context.sourceKey(for: sourceID)
            try db.execute(
                sql: "UPDATE source SET fileNamesFromIndex = ? WHERE key = ?",
                arguments: [index == nil ? 0 : 1, key]
            )
            try db.execute(sql: "UPDATE song SET fileNameOverride = NULL WHERE sourceKey = ? AND fileNameOverride IS NOT NULL", arguments: [key])
            if let index {
                let update = try db.makeStatement(sql: """
                    UPDATE song SET fileNameOverride = ? WHERE id = ? AND sourceKey = ? AND filePath = ?
                    """)
                for entry in index.values {
                    guard !entry.isDirectory, let name = entry.displayName, !name.isEmpty else { continue }
                    for songID in entry.songIDs {
                        try update.execute(arguments: [
                            LibraryCatalogDerivedFields.columnText(name), songID, key,
                            LibraryCatalogDerivedFields.columnText(entry.path),
                        ])
                    }
                }
                try db.execute(
                    sql: "UPDATE song SET fileNameKey = coalesce(fileNameOverride, title) WHERE sourceKey = ?",
                    arguments: [key]
                )
            } else {
                try context.recomputeFileNames(sourceKey: key)
            }
            try Self.bumpRevision(in: db)
        }
    }

    /// 本机播放次数(排序「播放次数」用)。键为歌曲 id,不在目录里的跳过。
    public func setLocalPlayCounts(_ counts: [String: Int]) throws {
        try pool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO songStat (songRowid, localPlayCount)
                SELECT rowid, ? FROM song WHERE id = ?
                ON CONFLICT(songRowid) DO UPDATE SET localPlayCount = excluded.localPlayCount
                """)
            for (id, count) in counts {
                try statement.execute(arguments: [count, id])
            }
        }
    }

    /// 标记下载完成/移除(排序与过滤「已下载」用)。
    public func setDownloaded(_ downloaded: Bool, songIDs: some Sequence<String>) throws {
        try pool.write { db in
            let statement = downloaded
                ? try db.makeStatement(sql: """
                    INSERT INTO songOffline (songRowid, state)
                    SELECT rowid, \(LibraryCatalogOfflineState.downloaded.rawValue) FROM song WHERE id = ?
                    ON CONFLICT(songRowid) DO UPDATE SET state = excluded.state
                    """)
                : try db.makeStatement(sql: """
                    DELETE FROM songOffline WHERE songRowid = (SELECT rowid FROM song WHERE id = ?)
                    """)
            for id in songIDs {
                try statement.execute(arguments: [id])
            }
        }
    }

    /// 音乐源启用/停用。只改 source 表,不重写歌曲。
    public func setSourceEnabled(_ enabled: Bool, sourceID: String) throws {
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            let key = try context.sourceKey(for: sourceID)
            try db.execute(sql: "UPDATE source SET enabled = ? WHERE key = ?", arguments: [enabled ? 1 : 0, key])
            // 书架只排可见的有声条目,停用/启用源都要重新归书。
            var grouping = GroupingMaintenance(db: db, configuration: groupingConfiguration)
            grouping.dirty.allBooks = true
            try grouping.rebuildBooks()
            try Self.bumpRevision(in: db)
        }
    }

    // MARK: - Write work (tests and diagnostics)

    /// 打开后,每次 `apply` 额外数 SQLite 执行的虚拟机指令(进度回调,有少量开销)。测试用。
    var measuresWriteWork: Bool {
        get { writeWorkState.withLock { $0.measures } }
        set { writeWorkState.withLock { $0.measures = newValue } }
    }

    /// 上一次 `apply` 的工作量。
    var lastWriteWork: LibraryCatalogWriteWork {
        writeWorkState.withLock { $0.last }
    }

    func recordWriteWork(_ work: LibraryCatalogWriteWork) {
        writeWorkState.withLock { $0.last = work }
    }
}

struct LibraryCatalogWriteWorkState: Sendable {
    var measures = false
    var last = LibraryCatalogWriteWork()
}

/// SQLite 进度回调:每执行 1000 条虚拟机指令记一次。只在测试里打开(GRDB 不用这个回调)。
final class CatalogWorkMeter {
    private let db: Database
    private var ticks = 0

    init(_ db: Database) {
        self.db = db
        sqlite3_progress_handler(db.sqliteConnection, 1_000, { context in
            guard let context else { return 0 }
            Unmanaged<CatalogWorkMeter>.fromOpaque(context).takeUnretainedValue().ticks += 1
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() -> Int {
        sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil)
        return ticks
    }
}

public enum LibraryCatalogOfflineState: Int, Sendable {
    case downloaded = 1
}

/// 一个写事务内的缓存与预编译语句。
struct SongWriteContext {
    enum UpsertOutcome {
        case inserted(Int64)
        case updated(Int64)
        case unchanged
    }

    struct SourceEntry {
        let key: Int64
        let traits: LibraryCatalogDerivedFields.SourceTraits
    }

    /// 一首要写的歌:存储列、派生列与逐行分组派生,都可以在写事务外多核先算好。
    struct PreparedRow: @unchecked Sendable {
        let song: Song
        let stored: LibraryCatalogSongCodec.StoredValues
        var derived: LibraryCatalogDerivedFields
        let grouping: GroupingMaintenance.RowValues
    }

    let db: Database
    private var sources: [String: SourceEntry] = [:]
    private var nextOrderKey: Int64?
    var recordsChanges = true

    init(db: Database) throws {
        self.db = db
    }

    /// 歌曲行写入的列(`id`、`orderKey` 之后),值顺序同 `values(sourceKey:prepared:)`。
    static let writeColumns = ["sourceKey"] + LibraryCatalogSongCodec.StoredValues.columnNames
        + LibraryCatalogDerivedFields.columnNames

    static let insertSQL: String = {
        let columns = ["id", "orderKey"] + writeColumns
        return """
            INSERT INTO song (\(columns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            """
    }()

    /// 已有行:物化用的列(`decode`)+ 源键 + 派生列 + 专辑归属。
    static let existingSQL = """
        SELECT \(LibraryCatalogSongCodec.selectColumns), song.sourceKey,
               \(LibraryCatalogDerivedFields.columnNames.map { "song.\($0)" }.joined(separator: ", ")),
               song.effectiveAlbumRef
        \(LibraryCatalogSongCodec.selectFrom) WHERE song.id = ?
        """
    private static let existingSourceKeyColumn = LibraryCatalogSongCodec.Column.extra + 1
    private static let existingDerivedColumn = existingSourceKeyColumn + 1
    private static let existingAlbumColumn = existingDerivedColumn + LibraryCatalogDerivedFields.columnNames.count

    static func values(sourceKey: Int64, stored: LibraryCatalogSongCodec.StoredValues, derived: LibraryCatalogDerivedFields) -> [CatalogValue] {
        [.int(sourceKey)] + stored.catalogValues + derived.values
    }

    mutating func sourceEntry(for sourceID: String) throws -> SourceEntry {
        if let entry = sources[sourceID] { return entry }
        guard !sourceID.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(sourceID) }
        try db.execute(sql: "INSERT OR IGNORE INTO source (id) VALUES (?)", arguments: [sourceID])
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT key, fileNamesFromIndex, usesFolderParents FROM source WHERE id = ?",
            arguments: [sourceID]
        ) else { throw LibraryCatalogError.corruptRow }
        let entry = SourceEntry(
            key: row[0],
            traits: .init(fileNamesFromIndex: (row[1] as Int) != 0, usesFolderParents: (row[2] as Int) != 0)
        )
        sources[sourceID] = entry
        return entry
    }

    mutating func sourceKey(for sourceID: String) throws -> Int64 {
        try sourceEntry(for: sourceID).key
    }

    private mutating func allocateOrderKey() throws -> Int64 {
        if nextOrderKey == nil {
            nextOrderKey = (try Int64.fetchOne(db, sql: "SELECT max(orderKey) FROM song") ?? -1) + 1
        }
        defer { nextOrderKey! += 1 }
        return nextOrderKey!
    }

    private func folderParent(sourceKey: Int64, filePath: String) throws -> String? {
        try String.fetchOne(
            db.cachedStatement(sql: "SELECT parent FROM fileParent WHERE sourceKey = ? AND filePath = ?"),
            arguments: [sourceKey, LibraryCatalogDerivedFields.columnText(filePath)]
        ).map(LibraryCatalogDerivedFields.columnText)
    }

    /// 先在写事务里解析各音乐源,再把每首的列值与逐行分组派生分到多个核上算好。
    mutating func prepare(
        _ songs: [Song],
        configuration: LibraryGroupingConfiguration,
        memo: GroupingMaintenance.RowValueMemo = GroupingMaintenance.RowValueMemo()
    ) throws -> [PreparedRow] {
        guard !songs.isEmpty else { return [] }
        var traits: [String: LibraryCatalogDerivedFields.SourceTraits] = [:]
        for song in songs where traits[song.sourceID] == nil {
            traits[song.sourceID] = try sourceEntry(for: song.sourceID).traits
        }
        return Self.prepareRows(songs, traits: traits, configuration: configuration, memo: memo)
    }

    /// `prepare` 里不碰数据库的部分:给定各音乐源的特征,把每首的列值与逐行分组派生分到多个核上算。
    /// 不在 `traits` 里的源按默认特征算,与 `sourceEntry` 新建的源一致。导入时在另一个线程上
    /// 提前算下一批(`memo` 同一时间只能有一个调用方)。
    static func prepareRows(
        _ songs: [Song],
        traits: [String: LibraryCatalogDerivedFields.SourceTraits],
        configuration: LibraryGroupingConfiguration,
        memo: GroupingMaintenance.RowValueMemo
    ) -> [PreparedRow] {
        guard !songs.isEmpty else { return [] }
        let grouping = LibraryCatalogImportProfile.measure("prepare.rowValues") {
            GroupingMaintenance.rowValues(for: songs, configuration: configuration, memo: memo)
        }
        return LibraryCatalogImportProfile.measure("prepare.encodeDerive") {
            ParallelSlots<PreparedRow>.map(count: songs.count, minimumSlice: 128) { range, out in
                for index in range {
                    let song = songs[index]
                    out.set(index, PreparedRow(
                        song: song,
                        stored: LibraryCatalogSongCodec.encode(song),
                        derived: LibraryCatalogDerivedFields.make(for: song, source: traits[song.sourceID] ?? .init(), fileNameOverride: nil),
                        grouping: grouping[index]
                    ))
                }
            }
        }
    }

    /// 目录里已有的各音乐源的特征(按 id)。
    static func sourceTraits(in db: Database) throws -> [String: LibraryCatalogDerivedFields.SourceTraits] {
        var traits: [String: LibraryCatalogDerivedFields.SourceTraits] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, fileNamesFromIndex, usesFolderParents FROM source") {
            traits[row[0]] = .init(fileNamesFromIndex: (row[1] as Int) != 0, usesFolderParents: (row[2] as Int) != 0)
        }
        return traits
    }

    /// 写一首歌:没有就追加到库尾,有就只改变了的列(变了的列所在的索引才会动)。
    mutating func upsert(_ row: PreparedRow, grouping: inout GroupingMaintenance) throws -> UpsertOutcome {
        guard !row.song.id.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(row.song.id) }
        let existing = try Row.fetchOne(db.cachedStatement(sql: Self.existingSQL), arguments: [row.song.id])
        guard let existing else {
            let orderKey = try allocateOrderKey()
            return .inserted(try insertNew(row, orderKey: orderKey, grouping: &grouping))
        }
        grouping.work.rowsRead += 1
        let previous = try LibraryCatalogSongCodec.decode(existing)
        // 按编码后的列比:浮点数的原始位也算在内(NaN 不等于自己,`Song ==` 判不出没变)。
        if previous.sourceID == row.song.sourceID, LibraryCatalogSongCodec.encode(previous) == row.stored {
            return .unchanged
        }
        let rowid: Int64 = existing[LibraryCatalogSongCodec.Column.rowid]
        try grouping.noteExisting(rowid: rowid)
        try grouping.removeDerivedRows(rowid: rowid)
        var derived = row.derived
        if previous.sourceID == row.song.sourceID, previous.filePath == row.song.filePath,
           let override: String = existing[Self.existingDerivedColumn + 1] {
            derived.fileNameOverride = override
            derived.fileNameKey = override
        }
        let source = try sourceEntry(for: row.song.sourceID)
        let folderKey = try complete(&derived, row: row, source: source, grouping: grouping)

        let newValues = Self.values(sourceKey: source.key, stored: row.stored, derived: derived)
        var oldValues: [CatalogValue] = [CatalogValue(existing[Self.existingSourceKeyColumn] as DatabaseValue)]
        for column in LibraryCatalogSongCodec.Column.title...LibraryCatalogSongCodec.Column.extra {
            oldValues.append(CatalogValue(existing[column] as DatabaseValue))
        }
        for offset in 0..<LibraryCatalogDerivedFields.columnNames.count {
            oldValues.append(CatalogValue(existing[Self.existingDerivedColumn + offset] as DatabaseValue))
        }
        var assignments: [String] = []
        var values: [CatalogValue] = []
        for index in newValues.indices where newValues[index] != oldValues[index] {
            assignments.append("\(Self.writeColumns[index]) = ?")
            values.append(newValues[index])
        }
        if derived.titleHash == nil, (existing[Self.existingAlbumColumn] as Int64?) != nil {
            assignments.append("effectiveAlbumRef = NULL")
        }
        if !assignments.isEmpty {
            let statement = try db.cachedStatement(sql: "UPDATE song SET \(assignments.joined(separator: ", ")) WHERE rowid = ?")
            values.append(.int(rowid))
            CatalogStatement.bind(values, to: statement)
            try CatalogStatement.execute(statement, in: db)
        }
        try recordChange(.updated, rowid: rowid, id: row.song.id)
        try writeGrouping(rowid: rowid, row: row, derived: derived, folderKey: folderKey, source: source, grouping: &grouping)
        return .updated(rowid)
    }

    /// 写一行确定不在目录里的新歌(导入、追加),连同逐行分组派生。
    mutating func insertNew(_ row: PreparedRow, orderKey: Int64, grouping: inout GroupingMaintenance) throws -> Int64 {
        guard !row.song.id.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(row.song.id) }
        let source = try sourceEntry(for: row.song.sourceID)
        var derived = row.derived
        let folderKey = try complete(&derived, row: row, source: source, grouping: grouping)
        let statement = try db.cachedStatement(sql: Self.insertSQL)
        CatalogStatement.bind([.text(row.song.id), .int(orderKey)], to: statement)
        CatalogStatement.bind(Self.values(sourceKey: source.key, stored: row.stored, derived: derived), to: statement, startingAt: 3)
        try CatalogStatement.execute(statement, in: db)
        let rowid = db.lastInsertedRowID
        if recordsChanges { try recordChange(.inserted, rowid: rowid, id: row.song.id) }
        try writeGrouping(rowid: rowid, row: row, derived: derived, folderKey: folderKey, source: source, grouping: &grouping)
        return rowid
    }

    /// 补上要在写事务里才知道的派生列:扫描索引给的父文件夹、所在文件夹的键、类别。
    private func complete(
        _ derived: inout LibraryCatalogDerivedFields,
        row: PreparedRow,
        source: SourceEntry,
        grouping: GroupingMaintenance
    ) throws -> Int64 {
        if source.traits.usesFolderParents {
            derived.inferenceDirectory = try folderParent(sourceKey: source.key, filePath: row.song.filePath)
        }
        let folderKey = try grouping.folderKey(sourceKey: source.key, path: row.grouping.folderPath)
        derived.kind = row.grouping.kind
        derived.folderKey = folderKey
        return folderKey
    }

    private func writeGrouping(
        rowid: Int64,
        row: PreparedRow,
        derived: LibraryCatalogDerivedFields,
        folderKey: Int64,
        source: SourceEntry,
        grouping: inout GroupingMaintenance
    ) throws {
        try grouping.writeRow(
            rowid: rowid,
            sourceKey: source.key,
            kind: derived.kind,
            folderKey: folderKey,
            directory: GroupingDirectory(
                usesFolderParents: source.traits.usesFolderParents, folderKey: folderKey,
                inferenceDirectory: derived.inferenceDirectory
            ),
            titleHash: derived.titleHash,
            mayBeInServerAlbum: row.song.serverCatalogAlbum != nil,
            values: row.grouping
        )
    }

    mutating func deleteSong(rowid: Int64, id: String) throws {
        for sql in [
            "DELETE FROM song WHERE rowid = ?",
            "DELETE FROM songStat WHERE songRowid = ?",
            "DELETE FROM songOffline WHERE songRowid = ?",
            "DELETE FROM songMaintenance WHERE songRowid = ?",
            "UPDATE playlistEntry SET songRowid = NULL WHERE songRowid = ?",
            "UPDATE likedSong SET songRowid = NULL WHERE songRowid = ?",
            "UPDATE dislikedSong SET songRowid = NULL WHERE songRowid = ?",
        ] {
            try db.cachedStatement(sql: sql).execute(arguments: [rowid])
        }
        try recordChange(.deleted, rowid: rowid, id: id)
    }

    private func recordChange(_ kind: LibraryCatalogChangeKind, rowid: Int64, id: String) throws {
        guard recordsChanges else { return }
        try db.cachedStatement(sql: "INSERT INTO catalogChange (kind, songRowid, songID) VALUES (?, ?, ?)")
            .execute(arguments: [kind.rawValue, rowid, id])
    }

    /// 按路径重算一个源的文件名列(取消「按扫描索引取名」时)。
    mutating func recomputeFileNames(sourceKey: Int64) throws {
        let update = try db.makeStatement(sql: "UPDATE song SET fileNameKey = ? WHERE rowid = ?")
        var lastRowid: Int64 = 0
        while true {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom)
                    WHERE song.sourceKey = ? AND song.rowid > ? ORDER BY song.rowid LIMIT ?
                    """,
                arguments: [sourceKey, lastRowid, LibraryScale.importBatchSize]
            )
            guard !rows.isEmpty else { return }
            for row in rows {
                let song = try LibraryCatalogSongCodec.decode(row)
                let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                try update.execute(arguments: [
                    LibraryCatalogDerivedFields.columnText(LibraryCatalogDerivedFields.fileName(for: song, fromIndex: false)), rowid,
                ])
                lastRowid = rowid
            }
        }
    }
}
