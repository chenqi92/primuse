import Foundation
import GRDB

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
    @discardableResult
    public func apply(upserts: [Song], deletingIDs: some Collection<String> = [String]()) throws -> LibraryCatalogChangeSummary {
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            var inserted = ContiguousArray<Int32>()
            var updated = ContiguousArray<Int32>()
            var deleted = ContiguousArray<Int32>()
            var unchanged = 0
            var deletedIDs = Set<String>()

            for id in deletingIDs where deletedIDs.insert(id).inserted {
                guard let rowid = try Int64.fetchOne(
                    db, sql: "SELECT rowid FROM song WHERE id = ?", arguments: [id]
                ) else { continue }
                try context.deleteSong(rowid: rowid, id: id)
                deleted.append(try Self.rowid32(rowid))
            }

            for incoming in upserts {
                let song = incoming.withoutAppliedPlaybackRange
                switch try context.upsert(song) {
                case .inserted(let rowid): inserted.append(try Self.rowid32(rowid))
                case .updated(let rowid): updated.append(try Self.rowid32(rowid))
                case .unchanged: unchanged += 1
                }
            }

            let revision = inserted.isEmpty && updated.isEmpty && deleted.isEmpty
                ? try Self.revision(in: db)
                : try Self.bumpRevision(in: db)
            return LibraryCatalogChangeSummary(
                revision: revision,
                insertedRowids: inserted,
                updatedRowids: updated,
                deletedRowids: deleted,
                unchangedCount: unchanged
            )
        }
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
            try db.execute(sql: "UPDATE song SET fileNameOverride = NULL WHERE sourceKey = ?", arguments: [key])
            if let index {
                let update = try db.makeStatement(sql: """
                    UPDATE song SET fileNameOverride = ? WHERE id = ? AND sourceKey = ? AND filePath = ?
                    """)
                for entry in index.values {
                    guard !entry.isDirectory, let name = entry.displayName, !name.isEmpty else { continue }
                    for songID in entry.songIDs {
                        try update.execute(arguments: [name, songID, key, entry.path])
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
            try Self.bumpRevision(in: db)
        }
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

    let db: Database
    private var sources: [String: SourceEntry] = [:]
    private var nextOrderKey: Int64?
    private var markedNonNFCIdentifier = false
    var recordsChanges = true

    init(db: Database) throws {
        self.db = db
    }

    static let upsertSQL: String = {
        let columns = ["id", "orderKey", "sourceKey"]
            + LibraryCatalogSongCodec.StoredValues.columnNames
            + LibraryCatalogDerivedFields.columnNames
        let updates = (["sourceKey"] + LibraryCatalogSongCodec.StoredValues.columnNames
            + LibraryCatalogDerivedFields.columnNames)
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        return """
            INSERT INTO song (\(columns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            ON CONFLICT(id) DO UPDATE SET \(updates)
            """
    }()

    static let insertSQL: String = {
        let columns = ["id", "orderKey", "sourceKey"]
            + LibraryCatalogSongCodec.StoredValues.columnNames
            + LibraryCatalogDerivedFields.columnNames
        return """
            INSERT INTO song (\(columns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            """
    }()

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

    private mutating func noteFlags(_ flags: Int) throws {
        guard flags & LibraryCatalogSongFlags.nonNFCIdentifier != 0, !markedNonNFCIdentifier else { return }
        try LibraryCatalog.setMeta(LibraryCatalog.MetaKey.nonNFCIdentifiers, "1", in: db)
        markedNonNFCIdentifier = true
    }

    private func folderParent(sourceKey: Int64, filePath: String, traits: LibraryCatalogDerivedFields.SourceTraits) throws -> String? {
        guard traits.usesFolderParents else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT parent FROM fileParent WHERE sourceKey = ? AND filePath = ?",
            arguments: [sourceKey, filePath]
        )
    }

    mutating func upsert(_ song: Song, beforeReplacing: (Int64) throws -> Void = { _ in }) throws -> UpsertOutcome {
        guard !song.id.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(song.id) }
        let source = try sourceEntry(for: song.sourceID)
        let existing = try Row.fetchOne(
            db,
            sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns), song.fileNameOverride
                \(LibraryCatalogSongCodec.selectFrom) WHERE song.id = ?
                """,
            arguments: [song.id]
        )
        var fileNameOverride: String?
        var rowid: Int64?
        if let existing {
            let previous = try LibraryCatalogSongCodec.decode(existing)
            // 按编码后的列比:浮点数的原始位也算在内(NaN 不等于自己,`Song ==` 判不出没变)。
            if previous.sourceID == song.sourceID,
               LibraryCatalogSongCodec.encode(previous) == LibraryCatalogSongCodec.encode(song) {
                return .unchanged
            }
            rowid = existing[LibraryCatalogSongCodec.Column.rowid]
            try beforeReplacing(rowid!)
            if previous.sourceID == song.sourceID, previous.filePath == song.filePath {
                fileNameOverride = existing[LibraryCatalogSongCodec.Column.extra + 1]
            }
        }
        let stored = LibraryCatalogSongCodec.encode(song)
        let derived = LibraryCatalogDerivedFields.make(
            for: song,
            source: source.traits,
            fileNameOverride: fileNameOverride,
            folderParent: try folderParent(sourceKey: source.key, filePath: song.filePath, traits: source.traits)
        )
        try noteFlags(derived.flags)
        let orderKey = rowid == nil ? try allocateOrderKey() : 0
        var values: [DatabaseValueConvertible?] = [song.id, orderKey, source.key]
        values.append(contentsOf: stored.databaseValues)
        values.append(contentsOf: derived.databaseValues)
        try db.cachedStatement(sql: Self.upsertSQL).execute(arguments: StatementArguments(values))
        if let rowid {
            try recordChange(.updated, rowid: rowid, id: song.id)
            return .updated(rowid)
        }
        let newRowid = db.lastInsertedRowID
        try recordChange(.inserted, rowid: newRowid, id: song.id)
        return .inserted(newRowid)
    }

    /// 一首新歌要写的全部列值(存储列 + 派生列),可以在写事务外、多核上先算好。
    struct PreparedRow: @unchecked Sendable {
        let song: Song
        let stored: LibraryCatalogSongCodec.StoredValues
        let derived: LibraryCatalogDerivedFields
    }

    /// 批量导入:先在写事务里解析各音乐源,再把每首的列值分到多个核上算好。
    mutating func prepareNew(_ songs: [Song]) throws -> [PreparedRow] {
        var traits: [String: LibraryCatalogDerivedFields.SourceTraits] = [:]
        for song in songs where traits[song.sourceID] == nil {
            let entry = try sourceEntry(for: song.sourceID)
            guard !entry.traits.usesFolderParents else {
                // 用文件夹表的源要逐行查父目录,走串行路径。
                return try songs.map { try prepareSerially($0) }
            }
            traits[song.sourceID] = entry.traits
        }
        let resolved = traits
        let slices = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, songs.count / 128))
        let sliceSize = (songs.count + slices - 1) / slices
        let output = PreparedRowSlots(count: songs.count)
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            let start = slice * sliceSize
            let end = min(songs.count, start + sliceSize)
            guard start < end else { return }
            for index in start..<end {
                let song = songs[index].withoutAppliedPlaybackRange
                output.slots[index] = PreparedRow(
                    song: song,
                    stored: LibraryCatalogSongCodec.encode(song),
                    derived: LibraryCatalogDerivedFields.make(
                        for: song, source: resolved[song.sourceID] ?? .init(), fileNameOverride: nil, folderParent: nil
                    )
                )
            }
        }
        return output.slots.map { $0! }
    }

    /// 每个下标只由一个片写一次,`concurrentPerform` 返回后才读。
    private final class PreparedRowSlots: @unchecked Sendable {
        let slots: UnsafeMutableBufferPointer<PreparedRow?>

        init(count: Int) {
            slots = .allocate(capacity: count)
            slots.initialize(repeating: nil)
        }

        deinit {
            slots.deinitialize()
            slots.deallocate()
        }
    }

    private mutating func prepareSerially(_ song: Song) throws -> PreparedRow {
        let source = try sourceEntry(for: song.sourceID)
        let clean = song.withoutAppliedPlaybackRange
        return PreparedRow(
            song: clean,
            stored: LibraryCatalogSongCodec.encode(clean),
            derived: LibraryCatalogDerivedFields.make(
                for: clean,
                source: source.traits,
                fileNameOverride: nil,
                folderParent: try folderParent(sourceKey: source.key, filePath: clean.filePath, traits: source.traits)
            )
        )
    }

    /// 写一行先算好的新歌。
    mutating func insertPrepared(_ row: PreparedRow, orderKey: Int64) throws -> Int64 {
        guard !row.song.id.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(row.song.id) }
        let source = try sourceEntry(for: row.song.sourceID)
        try noteFlags(row.derived.flags)
        var values: [DatabaseValueConvertible?] = [row.song.id, orderKey, source.key]
        values.append(contentsOf: row.stored.databaseValues)
        values.append(contentsOf: row.derived.databaseValues)
        try db.cachedStatement(sql: Self.insertSQL).execute(arguments: StatementArguments(values))
        let rowid = db.lastInsertedRowID
        if recordsChanges { try recordChange(.inserted, rowid: rowid, id: row.song.id) }
        return rowid
    }

    /// 批量导入:目标里确定没有这些 id,不查旧行。
    mutating func insertNew(_ song: Song, orderKey: Int64) throws -> Int64 {
        guard !song.id.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(song.id) }
        let source = try sourceEntry(for: song.sourceID)
        let stored = LibraryCatalogSongCodec.encode(song.withoutAppliedPlaybackRange)
        let derived = LibraryCatalogDerivedFields.make(
            for: song,
            source: source.traits,
            fileNameOverride: nil,
            folderParent: try folderParent(sourceKey: source.key, filePath: song.filePath, traits: source.traits)
        )
        try noteFlags(derived.flags)
        var values: [DatabaseValueConvertible?] = [song.id, orderKey, source.key]
        values.append(contentsOf: stored.databaseValues)
        values.append(contentsOf: derived.databaseValues)
        try db.cachedStatement(sql: Self.insertSQL).execute(arguments: StatementArguments(values))
        let rowid = db.lastInsertedRowID
        if recordsChanges { try recordChange(.inserted, rowid: rowid, id: song.id) }
        return rowid
    }

    mutating func deleteSong(rowid: Int64, id: String) throws {
        try db.execute(sql: "DELETE FROM song WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM songStat WHERE songRowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM songOffline WHERE songRowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM songMaintenance WHERE songRowid = ?", arguments: [rowid])
        try db.execute(sql: "UPDATE playlistEntry SET songRowid = NULL WHERE songRowid = ?", arguments: [rowid])
        try db.execute(sql: "UPDATE likedSong SET songRowid = NULL WHERE songRowid = ?", arguments: [rowid])
        try db.execute(sql: "UPDATE dislikedSong SET songRowid = NULL WHERE songRowid = ?", arguments: [rowid])
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
                try update.execute(arguments: [LibraryCatalogDerivedFields.fileName(for: song, fromIndex: false), rowid])
                lastRowid = rowid
            }
        }
    }
}
