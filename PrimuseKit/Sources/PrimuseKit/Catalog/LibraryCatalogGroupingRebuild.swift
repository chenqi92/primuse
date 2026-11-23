import Foundation
import GRDB

extension LibraryCatalog {
    /// 换分组输入。与上次重建时的指纹相同就什么也不做,否则整库重建(可取消、可续)。
    public func setGroupingConfiguration(
        _ configuration: LibraryGroupingConfiguration,
        isCancelled: () -> Bool = { false }
    ) throws {
        replaceGroupingConfiguration(configuration)
        let (stored, phase) = try pool.read { db in
            (try Self.metaValue(MetaKey.groupingFingerprint, in: db), try Self.metaValue(MetaKey.groupingRebuildPhase, in: db))
        }
        if stored == configuration.fingerprint, phase == nil { return }
        try rebuildGrouping(isCancelled: isCancelled)
    }

    /// 按需续上没做完的整库重建;没有就直接返回。
    public var groupingNeedsRebuild: Bool {
        get throws {
            try pool.read { db in
                try Self.metaValue(MetaKey.groupingRebuildPhase, in: db) != nil
                    || Self.metaValue(MetaKey.groupingFingerprint, in: db) != groupingConfiguration.fingerprint
            }
        }
    }

    enum RebuildPhase: String {
        case rows, authority, titles, assign, artists, finish
    }

    /// 整库重建时专辑归属先记在这张表里,最后按行号顺序一次回写歌曲表(按标题顺序直接回写
    /// 会把歌曲表的页反复写很多遍)。
    static let albumAssignmentTable = "groupingAlbumAssignment"

    /// 整库重建分组派生:逐行派生 → 文件夹计数与目录权威 → 按标题推断并聚合专辑 → 回写专辑归属
    /// → 艺人 → 统计/书。每批一个写事务,批间检查取消;进度记在 meta,被杀或取消后下次从断点继续。
    /// 每批按标题边界切,内存以一批(约 `LibraryScale.importBatchSize` 行,或最大的单个标题)为界。
    public func rebuildGrouping(isCancelled: () -> Bool = { false }) throws {
        let configuration = groupingConfiguration
        let fingerprint = configuration.fingerprint
        var (phase, cursor): (RebuildPhase, String) = try pool.write { db in
            let rebuildingFor = try Self.metaValue(MetaKey.groupingRebuildPhase, in: db)
                .flatMap { value -> (RebuildPhase, String)? in
                    let parts = value.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                    guard parts.count == 2, parts[1] == fingerprint, let phase = RebuildPhase(rawValue: parts[0]) else { return nil }
                    return (phase, try Self.metaValue(MetaKey.groupingRebuildCursor, in: db) ?? "")
                }
            if let rebuildingFor { return rebuildingFor }
            try Self.clearGrouping(in: db)
            for index in LibraryCatalogSchema.groupingIndexes {
                try db.execute(sql: "DROP INDEX IF EXISTS \(index.name)")
            }
            try Self.setMeta(MetaKey.groupingRebuildPhase, "\(RebuildPhase.rows.rawValue)\u{1}\(fingerprint)", in: db)
            try Self.setMeta(MetaKey.groupingRebuildCursor, "", in: db)
            return (.rows, "")
        }

        func advance(to next: RebuildPhase, in db: Database) throws {
            try Self.setMeta(MetaKey.groupingRebuildPhase, "\(next.rawValue)\u{1}\(fingerprint)", in: db)
            try Self.setMeta(MetaKey.groupingRebuildCursor, "", in: db)
            phase = next
            cursor = ""
        }

        let refs = CatalogRefCache()
        let memo = GroupingMaintenance.RowValueMemo()
        typealias Profile = LibraryCatalogImportProfile
        while true {
            if isCancelled() { throw LibraryCatalogError.cancelled }
            switch phase {
            case .rows:
                try Profile.measure("grouping.rows") { try pool.write { db in
                    let lastRowid = Int64(cursor) ?? 0
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns), song.sourceKey, song.kind, song.folderKey
                        \(LibraryCatalogSongCodec.selectFrom) WHERE song.rowid > ? ORDER BY song.rowid LIMIT ?
                        """, arguments: [lastRowid, LibraryScale.importBatchSize])
                    guard let last = rows.last else {
                        for index in LibraryCatalogSchema.linkIndexes { try db.execute(sql: index.sql) }
                        return try advance(to: .authority, in: db)
                    }
                    let lastRowidValue: Int64 = last[LibraryCatalogSongCodec.Column.rowid]
                    // 重建中途 `apply` 写过的行:先清掉,这一批统一重写。
                    for table in ["songArtist", "songArtistLookup", "songGenre", "songBook"] {
                        try db.execute(sql: "DELETE FROM \(table) WHERE songRowid > ? AND songRowid <= ?",
                                       arguments: [lastRowid, lastRowidValue])
                    }
                    let songs = try rows.map(LibraryCatalogSongCodec.decode)
                    let values = GroupingMaintenance.rowValues(for: songs, configuration: configuration, memo: memo)
                    var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    grouping.tracksDirty = false
                    let base = LibraryCatalogSongCodec.Column.extra + 1
                    let update = try db.cachedStatement(sql: "UPDATE song SET kind = ?, folderKey = ? WHERE rowid = ?")
                    for (index, row) in rows.enumerated() {
                        let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                        let sourceKey: Int64 = row[base]
                        let folderKey = try grouping.folderKey(sourceKey: sourceKey, path: values[index].folderPath)
                        if (row[base + 1] as Int) != values[index].kind || (row[base + 2] as Int64?) != folderKey {
                            try update.execute(arguments: [values[index].kind, folderKey, rowid])
                        }
                        try grouping.writeRow(
                            rowid: rowid, sourceKey: sourceKey, kind: values[index].kind, folderKey: folderKey,
                            directory: nil, titleHash: nil, mayBeInServerAlbum: false, values: values[index]
                        )
                    }
                    cursor = String(lastRowidValue)
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .authority:
                try Profile.measure("grouping.authority") { try pool.write { db in
                    let grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    try grouping.recountAllFolders()
                    for row in try Row.fetchAll(db, sql: "SELECT key, usesFolderParents FROM source") {
                        let key: Int64 = row[0]
                        let authority = try GroupingMaintenance.hasDirectoryAuthority(
                            sourceKey: key, usesFolderParents: (row[1] as Int) != 0, in: db
                        )
                        try db.execute(sql: "UPDATE source SET hasDirectoryAuthority = ? WHERE key = ?", arguments: [authority ? 1 : 0, key])
                    }
                    for index in LibraryCatalogSchema.linkIndexes { try db.execute(sql: index.sql) }
                    try db.execute(sql: """
                        DELETE FROM album; DELETE FROM albumSourceStat; DELETE FROM albumArtistCredit;
                        DROP TABLE IF EXISTS \(Self.albumAssignmentTable);
                        CREATE TABLE \(Self.albumAssignmentTable) (songRowid INTEGER PRIMARY KEY, albumRef INTEGER NOT NULL);
                        """)
                    refs.forgetAlbums()
                    try advance(to: .titles, in: db)
                } }
            case .titles:
                try Profile.measure("grouping.titles") { try pool.write { db in
                    var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    grouping.tracksDirty = false
                    guard try rebuildTitleBatch(after: Int64(cursor), grouping: &grouping, cursor: &cursor) else {
                        return try advance(to: .assign, in: db)
                    }
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .assign:
                try Profile.measure("grouping.assign") { try pool.write { db in
                    let lastRowid = Int64(cursor) ?? 0
                    if cursor.isEmpty { try db.execute(sql: "DROP INDEX IF EXISTS \(LibraryCatalogSchema.albumIndex.name)") }
                    let maximum = try Int64.fetchOne(db, sql: "SELECT max(rowid) FROM song") ?? 0
                    guard lastRowid < maximum else {
                        try db.execute(sql: LibraryCatalogSchema.albumIndex.sql)
                        try db.execute(sql: "DROP TABLE IF EXISTS \(Self.albumAssignmentTable)")
                        return try advance(to: .artists, in: db)
                    }
                    let end = lastRowid + Int64(Self.assignmentBatchSize)
                    try db.execute(sql: """
                        UPDATE song SET effectiveAlbumRef = (
                            SELECT albumRef FROM \(Self.albumAssignmentTable) a WHERE a.songRowid = song.rowid)
                        WHERE rowid > ? AND rowid <= ? AND effectiveAlbumRef IS NOT (
                            SELECT albumRef FROM \(Self.albumAssignmentTable) a WHERE a.songRowid = song.rowid)
                        """, arguments: [lastRowid, end])
                    cursor = String(end)
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .artists:
                try Profile.measure("grouping.artists") { try pool.write { db in
                    var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    try grouping.rebuildAllArtists()
                    try advance(to: .finish, in: db)
                } }
            case .finish:
                try Profile.measure("grouping.finish") { try pool.write { db in
                    var grouping = GroupingMaintenance(db: db, configuration: configuration, refs: refs)
                    try grouping.rebuildAllArtistStats()
                    grouping.dirty.allBooks = true
                    try grouping.rebuildBooks()
                    try Self.setMeta(MetaKey.groupingFingerprint, fingerprint, in: db)
                    try Self.removeMeta(MetaKey.groupingRebuildPhase, in: db)
                    try Self.removeMeta(MetaKey.groupingRebuildCursor, in: db)
                    let generation = (try Self.metaValue(MetaKey.groupingGeneration, in: db).flatMap(Int64.init) ?? 0) + 1
                    try Self.setMeta(MetaKey.groupingGeneration, String(generation), in: db)
                    try Self.bumpRevision(in: db)
                } }
                return
            }
        }
    }

    static let assignmentBatchSize = 50_000

    /// 一批完整的标题(按标题哈希,批尾那个标题整个带上):推断专辑艺人(按标题多核分片)、建专辑行、
    /// 从这批的行直接聚合专辑(一张专辑的歌必在同一个标题里)、记下每首的专辑。没有更多标题时返回 false。
    private func rebuildTitleBatch(
        after previous: Int64?,
        grouping: inout GroupingMaintenance,
        cursor: inout String
    ) throws -> Bool {
        typealias Profile = LibraryCatalogImportProfile
        let db = grouping.db
        let lower = previous == nil ? "s.titleHash IS NOT NULL" : "s.titleHash > ?"
        let lowerArguments = previous.map { StatementArguments([$0]) } ?? StatementArguments()
        // 用游标边读边解码:不先把整批行复制成 `Row`(未优化的编译里逐行复制是这一步的大头)。
        var fields: [LibraryCatalogSongCodec.GroupingFields] = []
        var credits: [Set<Int64>] = []
        try Profile.measure("titles.read") {
            let end = try Int64.fetchOne(db, sql: """
                SELECT s.titleHash FROM song s WHERE \(lower) ORDER BY s.titleHash LIMIT 1 OFFSET ?
                """, arguments: lowerArguments + StatementArguments([LibraryScale.importBatchSize]))
            let upper = end == nil ? "" : " AND s.titleHash <= ?"
            let batchRows = try Row.fetchCursor(db, sql: """
                SELECT \(LibraryCatalogSongCodec.groupingColumns),
                       (SELECT group_concat(sa.artistRef) FROM songArtist sa WHERE sa.songRowid = s.rowid)
                FROM song s WHERE \(lower)\(upper) ORDER BY s.titleHash, s.rowid
                """, arguments: lowerArguments + (end.map { StatementArguments([$0]) } ?? StatementArguments()))
            while let row = try batchRows.next() {
                fields.append(try LibraryCatalogSongCodec.decodeGroupingFields(row))
                let text: String? = row[LibraryCatalogSongCodec.groupingColumnCount]
                credits.append(text.map { Set($0.split(separator: ",").compactMap { Int64($0) }) } ?? [])
            }
        }
        guard !fields.isEmpty else { return false }
        // 按标题哈希切片(标题之间互不影响),多核推断。
        var boundaries: [Int] = [0]
        for index in 1..<fields.count where fields[index].titleHash != fields[index - 1].titleHash {
            boundaries.append(index)
        }
        boundaries.append(fields.count)
        let sources = try grouping.allSources()
        let configuration = grouping.configuration
        let chunkCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount * 2), boundaries.count - 1)
        let groupsPerChunk = (boundaries.count - 1 + chunkCount - 1) / chunkCount
        let chunks: [Range<Int>] = stride(from: 0, to: boundaries.count - 1, by: groupsPerChunk).map {
            boundaries[$0]..<boundaries[min($0 + groupsPerChunk, boundaries.count - 1)]
        }
        let identities = Profile.measure("titles.identities") {
            ParallelSlots<[AlbumGroupingIdentity?]>.map(count: chunks.count, minimumSlice: 1) { range, out in
                for chunk in range {
                    out.set(chunk, GroupingMaintenance.albumIdentities(
                        for: Array(fields[chunks[chunk]]), sources: sources, configuration: configuration
                    ))
                }
            }.flatMap { $0 }
        }

        let assign = try db.cachedStatement(sql: "INSERT INTO \(Self.albumAssignmentTable) (songRowid, albumRef) VALUES (?, ?)")
        var albumOrder: [Int64] = []
        var members: [Int64: [AlbumMember]] = [:]
        var firstFields: [Int64: LibraryCatalogSongCodec.GroupingFields] = [:]
        // 一张专辑的歌共用同一个身份:专辑键与专辑艺人引用每个身份只算一次(各要一次 SHA-256)。
        // 键按 UTF-8 字节比,不用 `AlbumGroupingIdentity` 的 `==`(Swift 字符串按规范等价比,
        // 而专辑 id 哈希的是字节:NFC/NFD 两种写法是两张专辑)。首次出现时的写入与原来同序。
        var resolvedIdentities: [AlbumIdentityBytes: (albumKey: Int64, artistRef: Int64)] = [:]
        try Profile.measure("titles.assign") {
            for (index, row) in fields.enumerated() {
                guard let identity = identities[index] else { continue }
                let identityKey = AlbumIdentityBytes(identity)
                let albumKey: Int64
                let artistRef: Int64
                if let resolved = resolvedIdentities[identityKey] {
                    (albumKey, artistRef) = resolved
                } else {
                    albumKey = try grouping.albumKey(for: identity)
                    artistRef = try grouping.refs.artistRef(
                        LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(identity.artistName)), in: db
                    )
                    resolvedIdentities[identityKey] = (albumKey, artistRef)
                }
                CatalogStatement.bind([.int(row.rowid), .int(albumKey)], to: assign)
                try CatalogStatement.execute(assign, in: db)
                if members[albumKey] == nil {
                    albumOrder.append(albumKey)
                    firstFields[albumKey] = row
                }
                members[albumKey, default: []].append(AlbumMember(
                    rowid: row.rowid, year: row.year, sourceKey: row.sourceKey, kind: row.kind, duration: row.durationKey,
                    dateAdded: row.dateAdded, credited: credits[index].contains(artistRef)
                ))
            }
        }
        try Profile.measure("titles.aggregate") {
            for albumKey in albumOrder {
                // 同一标题内按 (标题哈希, 行号) 读出,专辑成员已是库内顺序。
                guard let aggregate = AlbumAggregate(members: members[albumKey] ?? []), let first = firstFields[albumKey] else { continue }
                try grouping.writeAlbumAggregate(
                    key: albumKey, aggregate: aggregate, genre: first.genre, sourceID: sources[first.sourceKey]?.id ?? ""
                )
            }
        }
        cursor = String(fields[fields.count - 1].titleHash ?? 0)
        return true
    }

    /// 重建还没做完时有写入:跨行的分组从「目录权威」重来(逐行派生已随写入做好;
    /// 还在逐行阶段时,游标之后的行会被那个阶段重写)。
    static func restartRebuildAfterWrite(in db: Database) throws {
        guard let value = try metaValue(MetaKey.groupingRebuildPhase, in: db) else { return }
        let parts = value.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        guard parts.count == 2, let phase = RebuildPhase(rawValue: parts[0]), phase != .rows else { return }
        try setMeta(MetaKey.groupingRebuildPhase, "\(RebuildPhase.authority.rawValue)\u{1}\(parts[1])", in: db)
        try setMeta(MetaKey.groupingRebuildCursor, "", in: db)
    }

    /// 清空全部分组派生(整库重建从逐行阶段开始时)。
    static func clearGrouping(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM songArtist; DELETE FROM songArtistLookup; DELETE FROM songGenre;
            DELETE FROM songBook; DELETE FROM book;
            DELETE FROM album; DELETE FROM albumSourceStat; DELETE FROM albumArtistCredit;
            DELETE FROM artist; DELETE FROM artistSourceStat; DELETE FROM artistRef; DELETE FROM genreName;
            UPDATE song SET effectiveAlbumRef = NULL WHERE effectiveAlbumRef IS NOT NULL;
            DROP TABLE IF EXISTS \(albumAssignmentTable);
            """)
    }

    /// 网盘这类按条目 id 寻址的源:文件所在的文件夹不在路径里,由扫描索引给出
    /// (`AlbumArtistFolderIndex`)。传 nil 恢复按路径取目录。只重推断这个源的标题。
    public func setFolderParents(sourceID: String, parents: [String: String]?) throws {
        let configuration = groupingConfiguration
        try pool.write { db in
            var context = try SongWriteContext(db: db)
            let key = try context.sourceKey(for: sourceID)
            try db.execute(sql: "DELETE FROM fileParent WHERE sourceKey = ?", arguments: [key])
            try db.execute(
                sql: "UPDATE source SET usesFolderParents = ? WHERE key = ?",
                arguments: [parents == nil ? 0 : 1, key]
            )
            if let parents {
                let insert = try db.makeStatement(sql: "INSERT INTO fileParent (sourceKey, filePath, parent) VALUES (?, ?, ?)")
                for (path, parent) in parents {
                    try insert.execute(arguments: [
                        key, LibraryCatalogDerivedFields.columnText(path), LibraryCatalogDerivedFields.columnText(parent),
                    ])
                }
                try db.execute(sql: """
                    UPDATE song SET inferenceDirectory = (
                        SELECT parent FROM fileParent WHERE fileParent.sourceKey = song.sourceKey AND fileParent.filePath = song.filePath)
                    WHERE sourceKey = ?
                    """, arguments: [key])
            } else {
                try db.execute(sql: "UPDATE song SET inferenceDirectory = NULL WHERE sourceKey = ?", arguments: [key])
            }
            if try Self.metaValue(MetaKey.groupingRebuildPhase, in: db) != nil {
                try Self.restartRebuildAfterWrite(in: db)
            } else {
                var grouping = GroupingMaintenance(db: db, configuration: configuration)
                grouping.dirty.sources.insert(key)
                for titleHash in try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT titleHash FROM song WHERE sourceKey = ? AND titleHash IS NOT NULL
                    """, arguments: [key]) {
                    grouping.dirty.sourceTitles.insert(GroupingSourceTitle(sourceKey: key, titleHash: titleHash))
                }
                try grouping.flush()
            }
            try Self.bumpRevision(in: db)
        }
    }
}

/// 专辑身份按 UTF-8 字节比较的字典键(专辑 id、艺人 id 都哈希字节)。
private struct AlbumIdentityBytes: Hashable {
    let albumTitle: [UInt8]
    let artistName: [UInt8]

    init(_ identity: AlbumGroupingIdentity) {
        albumTitle = Array(identity.albumTitle.utf8)
        artistName = Array(identity.artistName.utf8)
    }
}
