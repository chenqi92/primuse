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

    private enum RebuildPhase: String {
        case rows, authority, titles, albums, artists, finish
    }

    /// 整库重建分组派生:逐行派生 → 目录权威 → 按标题推断 → 专辑 → 艺人 → 统计/书/文件夹。
    /// 每批一个写事务,批间检查取消;进度记在 meta,被杀或取消后下次从断点继续。
    /// 内存以最大的单个范围(最大的标题、专辑或艺人)为界。
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
            try db.execute(sql: """
                DELETE FROM songArtist; DELETE FROM songArtistLookup; DELETE FROM songGenre;
                DELETE FROM album; DELETE FROM albumSourceStat; DELETE FROM albumArtistCredit;
                DELETE FROM artist; DELETE FROM artistSourceStat; DELETE FROM songBook; DELETE FROM book;
                UPDATE song SET effectiveAlbumID = NULL, effectiveAlbumArtist = NULL;
                UPDATE song SET folderKey = NULL; DELETE FROM folder;
                """)
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

        while true {
            if isCancelled() { throw LibraryCatalogError.cancelled }
            switch phase {
            case .rows:
                try LibraryCatalogImportProfile.measure("grouping.rows") { try pool.write { db in
                    let lastRowid = Int64(cursor) ?? 0
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns), song.sourceKey, song.kind, song.folderKey
                        \(LibraryCatalogSongCodec.selectFrom) WHERE song.rowid > ? ORDER BY song.rowid LIMIT ?
                        """, arguments: [lastRowid, 8_000])
                    guard let last = rows.last else { return try advance(to: .authority, in: db) }
                    var grouping = GroupingMaintenance(db: db, configuration: configuration)
                    grouping.collectsDirty = false
                    let songs = try rows.map(LibraryCatalogSongCodec.decode)
                    let values = GroupingMaintenance.rowValues(for: songs, configuration: configuration)
                    let base = LibraryCatalogSongCodec.Column.extra + 1
                    for (index, row) in rows.enumerated() {
                        try grouping.writeRow(
                            rowid: row[LibraryCatalogSongCodec.Column.rowid], sourceKey: row[base],
                            values: values[index], fresh: true, current: (row[base + 1], nil)
                        )
                    }
                    let lastRowidValue: Int64 = last[LibraryCatalogSongCodec.Column.rowid]
                    cursor = String(lastRowidValue)
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .authority:
                try LibraryCatalogImportProfile.measure("grouping.authority") { try pool.write { db in
                    for sourceKey in try Int64.fetchAll(db, sql: "SELECT key FROM source") {
                        let distinct = try Int.fetchOne(db, sql: """
                            SELECT count(*) FROM (SELECT DISTINCT \(GroupingMaintenance.inferenceDirectorySQL) AS directory
                            FROM song JOIN source ON source.key = song.sourceKey
                            WHERE song.sourceKey = ? AND directory IS NOT NULL LIMIT 2)
                            """, arguments: [sourceKey]) ?? 0
                        try db.execute(sql: "UPDATE source SET hasDirectoryAuthority = ? WHERE key = ?",
                                       arguments: [distinct >= 2 ? 1 : 0, sourceKey])
                    }
                    try advance(to: .titles, in: db)
                } }
            case .titles:
                try LibraryCatalogImportProfile.measure("grouping.titles") { try pool.write { db in
                    let titles = try String.fetchAll(db, sql: """
                        SELECT DISTINCT albumTitleKey FROM song WHERE albumTitleKey > ? ORDER BY albumTitleKey LIMIT 200
                        """, arguments: [cursor])
                    guard let last = titles.last else { return try advance(to: .albums, in: db) }
                    var grouping = GroupingMaintenance(db: db, configuration: configuration)
                    grouping.collectsDirty = false
                    try grouping.regroupTitles(titles)
                    cursor = last
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .albums:
                try LibraryCatalogImportProfile.measure("grouping.albums") { try pool.write { db in
                    let albums = try String.fetchAll(db, sql: """
                        SELECT DISTINCT effectiveAlbumID FROM song WHERE effectiveAlbumID > ? ORDER BY effectiveAlbumID LIMIT 200
                        """, arguments: [cursor])
                    guard let last = albums.last else { return try advance(to: .artists, in: db) }
                    var grouping = GroupingMaintenance(db: db, configuration: configuration)
                    grouping.collectsDirty = false
                    try grouping.rebuildAlbums(albums)
                    cursor = last
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .artists:
                try LibraryCatalogImportProfile.measure("grouping.artists") { try pool.write { db in
                    let artists = try String.fetchAll(db, sql: """
                        SELECT DISTINCT artistID FROM songArtist WHERE artistID > ? ORDER BY artistID LIMIT 200
                        """, arguments: [cursor])
                    guard let last = artists.last else { return try advance(to: .finish, in: db) }
                    var grouping = GroupingMaintenance(db: db, configuration: configuration)
                    grouping.collectsDirty = false
                    try grouping.rebuildArtists(artists)
                    cursor = last
                    try Self.setMeta(MetaKey.groupingRebuildCursor, cursor, in: db)
                } }
            case .finish:
                try LibraryCatalogImportProfile.measure("grouping.finish") { try pool.write { db in
                    var grouping = GroupingMaintenance(db: db, configuration: configuration)
                    try grouping.rebuildAllArtistStats()
                    try grouping.recountAllFolders()
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
                for (path, parent) in parents { try insert.execute(arguments: [key, path, parent]) }
                try db.execute(sql: """
                    UPDATE song SET inferenceDirectory = (
                        SELECT parent FROM fileParent WHERE fileParent.sourceKey = song.sourceKey AND fileParent.filePath = song.filePath)
                    WHERE sourceKey = ?
                    """, arguments: [key])
            } else {
                try db.execute(sql: "UPDATE song SET inferenceDirectory = NULL WHERE sourceKey = ?", arguments: [key])
            }
            var grouping = GroupingMaintenance(db: db, configuration: configuration)
            grouping.dirty.sources.insert(key)
            grouping.dirty.sourcesWithRemovals.insert(key)
            for title in try String.fetchAll(db, sql: """
                SELECT DISTINCT albumTitleKey FROM song WHERE sourceKey = ? AND albumTitleKey IS NOT NULL
                """, arguments: [key]) {
                grouping.dirty.titles.insert(title)
            }
            try grouping.flush()
            try Self.bumpRevision(in: db)
        }
    }
}
