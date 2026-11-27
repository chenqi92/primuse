import Foundation
import GRDB

/// 专辑、艺人等分组列表:整范围只给键列表(`ContiguousArray<Int32>`),物化按键分批、有上限。
public struct LibraryCatalogKeyList: Sendable, Equatable {
    public let keys: ContiguousArray<Int32>
    public let revision: Int64
    public var count: Int { keys.count }
}

extension LibraryCatalog {
    static let enabledSourcesSQL = "SELECT key FROM source WHERE enabled = 1"

    /// 可见集是否要与整库不同:停用了源,或可见歌曲里有非音乐内容(参照实现的分支条件)。
    ///
    /// 「不是音乐」写成 `kind > 0`(类别从 0 起,见 `LibraryCatalogContentKind`),走以 `kind` 打头的排序索引:
    /// 可见歌曲里一首非音乐都没有时一步就答完。写成 `kind != 0` 用不上索引,那种库里每问一次都把歌曲表
    /// 扫到底(10 万首约 20 ms,50 万首约 100 ms,专辑、艺人的每一页都要问)。`+sourceKey` 不让规划器改走
    /// 按源的索引(那样要把启用源的歌逐首回表看类别)。排序索引还没建好时照样对,只是又成了整表扫。
    static func visibleSplitsLibrary(in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS (SELECT 1 FROM source WHERE enabled = 0)
                OR EXISTS (SELECT 1 FROM song WHERE kind > 0 AND +sourceKey IN (\(enabledSourcesSQL)))
            """)) ?? false
    }

    // MARK: - Albums

    /// 专辑按标题本地化排序、同名按首次出现的先后(与参照实现的稳定排序一致)。
    /// `visibleOnly` 只要有可见音乐歌曲的专辑。
    public func albumKeys(visibleOnly: Bool = true) throws -> LibraryCatalogKeyList {
        try reader.read { db in
            let revision = try Self.revision(in: db)
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let filter = visibleOnly && splitsLibrary
                ? """
                  WHERE album.key IN (SELECT albumKey FROM albumSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            var keys = ContiguousArray<Int32>()
            let cursor = try Int64.fetchCursor(db, sql: """
                SELECT key FROM album \(filter)
                ORDER BY title COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid
                """)
            while let key = try cursor.next() { keys.append(try Self.rowid32(key)) }
            return LibraryCatalogKeyList(keys: keys, revision: revision)
        }
    }

    /// 按键物化专辑,保持顺序。`visibleCounts` 时歌曲数与时长只算已启用源的歌(所有类别)。
    public func albums(keys: some Collection<Int32>, visibleCounts: Bool = true) throws -> [Album] {
        let admitted = Array(keys.prefix(LibraryScaleGuard.admitMaterialization(count: keys.count)))
        return try reader.read { db in
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            return try Self.fetchAlbums(keys: admitted, splits: visibleCounts && splitsLibrary, in: db)
        }
    }

    /// 可见专辑里按 id 取一张:它在 `albumKeys(visibleOnly: true)` 里时给出与 `albums(keys:visibleCounts: true)`
    /// 相同的那一项(歌曲数与时长只算可见的歌),不在(没有这张专辑,或它没有可见的音乐)时为 nil。
    public func visibleAlbum(id: String) throws -> Album? {
        try pointReadOfGrouping { db in
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? " AND key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            guard let key = try Int64.fetchOne(db, sql: "SELECT key FROM album WHERE id = ?\(filter)", arguments: [id]) else {
                return nil
            }
            return try Self.fetchAlbums(keys: [try Self.rowid32(key)], splits: splits, in: db).first
        }
    }

    private static func fetchAlbums(keys admitted: [Int32], splits: Bool, in db: Database) throws -> [Album] {
        var byKey: [Int32: Album] = [:]
        for chunk in Self.chunks(of: admitted) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.key, a.id, a.title, a.artistID, a.artistName, a.year, a.genre, a.songCount, a.duration,
                       a.sourceID, a.sourceArtistNames,
                       (SELECT total(songCount) FROM albumSourceStat st
                           WHERE st.albumKey = a.key AND st.sourceKey IN (\(Self.enabledSourcesSQL))),
                       (SELECT total(duration) FROM albumSourceStat st
                           WHERE st.albumKey = a.key AND st.sourceKey IN (\(Self.enabledSourcesSQL)))
                FROM album a WHERE a.key IN (\(Self.placeholders(chunk.count)))
                """, arguments: StatementArguments(chunk.map(Int64.init)))
            for row in rows {
                let key = try Self.rowid32(row[0])
                let visibleCount: Double = row[11]
                let visibleDuration: Double = row[12]
                byKey[key] = Album(
                    id: row[1], title: row[2], artistID: row[3], artistName: row[4],
                    sourceArtistNames: GroupingMaintenance.decodeSourceArtistNames(row[10]),
                    year: row[5], genre: row[6],
                    songCount: splits ? Int(visibleCount) : row[7],
                    totalDuration: splits ? visibleDuration : row[8],
                    sourceID: row[9]
                )
            }
        }
        return admitted.compactMap { byKey[$0] }
    }

    /// 专辑的可见歌曲,按碟号、曲号、标题(`AlbumTrackOrder`)。
    public func albumSongRowList(albumID: String) throws -> LibraryRowList {
        try rowList(orderBy: "s.discKey, s.trackKey, s.title COLLATE \(LibraryCatalogSchema.localizedStandardCollation), s.id") { _ in
            ("s.effectiveAlbumRef = (SELECT key FROM album WHERE id = ?) AND s.sourceKey IN (\(Self.enabledSourcesSQL))", [albumID])
        }
    }

    /// 专辑封面回退用的那首:有封面的优先,再按碟号、曲号、id(可见歌曲,所有类别)。
    public func preferredArtworkSongID(albumID: String) throws -> String? {
        try reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM song WHERE effectiveAlbumRef = (SELECT key FROM album WHERE id = ?)
                AND sourceKey IN (\(Self.enabledSourcesSQL))
                ORDER BY \(Self.artworkFallbackOrder) LIMIT 1
                """, arguments: [albumID])
        }
    }

    static let artworkFallbackOrder = """
        (flags & \(LibraryCatalogSongFlags.hasCover)) = 0, coalesce(discNumber, 9223372036854775807),
        coalesce(trackNumber, 9223372036854775807), id
        """

    // MARK: - Artists

    /// 艺人按名字本地化排序、同名按首次出现的先后。`visibleOnly` 时停用了源或分出了非音乐
    /// 内容就只要有可见音乐歌曲的艺人(按查找 id 计)。
    public func artistKeys(visibleOnly: Bool = true) throws -> LibraryCatalogKeyList {
        try reader.read { db in
            let revision = try Self.revision(in: db)
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let filter = visibleOnly && splitsLibrary
                ? """
                  WHERE artist.key IN (SELECT artistRef FROM artistSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            var keys = ContiguousArray<Int32>()
            let cursor = try Int64.fetchCursor(db, sql: """
                SELECT key FROM artist \(filter)
                ORDER BY name COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid, firstOrdinal
                """)
            while let key = try cursor.next() { keys.append(try Self.rowid32(key)) }
            return LibraryCatalogKeyList(keys: keys, revision: revision)
        }
    }

    public func artists(keys: some Collection<Int32>, visibleCounts: Bool = true) throws -> [Artist] {
        let admitted = Array(keys.prefix(LibraryScaleGuard.admitMaterialization(count: keys.count)))
        return try reader.read { db in
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            return try Self.fetchArtists(keys: admitted, splits: visibleCounts && splitsLibrary, in: db)
        }
    }

    /// 可见艺人里按 id 取一位:他在 `artistKeys(visibleOnly: true)` 里时给出与 `artists(keys:visibleCounts: true)`
    /// 相同的那一项,不在(没有这位艺人,或他没有可见的音乐)时为 nil。艺人键就是 `artistRef` 的引用号。
    public func visibleArtist(id: String) throws -> Artist? {
        try pointReadOfGrouping { db in
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? " AND key IN (SELECT artistRef FROM artistSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            guard let key = try Int64.fetchOne(db, sql: """
                SELECT key FROM artist WHERE key = (SELECT ref FROM artistRef WHERE id = ?)\(filter)
                """, arguments: [id]) else { return nil }
            return try Self.fetchArtists(keys: [try Self.rowid32(key)], splits: splits, in: db).first
        }
    }

    private static func fetchArtists(keys admitted: [Int32], splits: Bool, in db: Database) throws -> [Artist] {
        var byKey: [Int32: Artist] = [:]
        for chunk in Self.chunks(of: admitted) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.key, a.id, a.name, a.albumCount, a.songCount, a.thumbnailPath,
                       (SELECT total(songCount) FROM artistSourceStat st
                           WHERE st.artistRef = a.key AND st.sourceKey IN (\(Self.enabledSourcesSQL)))
                FROM artist a WHERE a.key IN (\(Self.placeholders(chunk.count)))
                """, arguments: StatementArguments(chunk.map(Int64.init)))
            for row in rows {
                let visibleCount: Double = row[6]
                byKey[try Self.rowid32(row[0])] = Artist(
                    id: row[1], name: row[2], albumCount: row[3],
                    songCount: splits ? Int(visibleCount) : row[4], thumbnailPath: row[5]
                )
            }
        }
        return admitted.compactMap { byKey[$0] }
    }

    /// 艺人的可见歌曲(按查找 id,与艺人页一致),库内顺序。
    public func artistSongRowList(artistID: String) throws -> LibraryRowList {
        try rowList { _ in
            ("""
             s.rowid IN (SELECT songRowid FROM songArtistLookup
                 WHERE artistRef = (SELECT ref FROM artistRef WHERE id = ?))
             AND s.sourceKey IN (\(Self.enabledSourcesSQL))
             """, [artistID])
        }
    }

    public func preferredArtworkSongID(artistID: String) throws -> String? {
        try reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM song WHERE rowid IN (SELECT songRowid FROM songArtistLookup
                    WHERE artistRef = (SELECT ref FROM artistRef WHERE id = ?))
                AND sourceKey IN (\(Self.enabledSourcesSQL)) ORDER BY \(Self.artworkFallbackOrder) LIMIT 1
                """, arguments: [artistID])
        }
    }

    /// 专辑艺人浏览(`AlbumArtistIndexBuilder`):用目录里的可见专辑与可见艺人跑参照实现。
    /// 结果与专辑数同阶,只给差分测试与 P2 迁移前的过渡使用。
    func albumArtistIndexForReference() throws -> AlbumArtistIndex {
        let albumList = try albumKeys(visibleOnly: true)
        let artistList = try artistKeys(visibleOnly: true)
        var albums: [Album] = []
        for chunk in Self.chunks(of: Array(albumList.keys), size: LibraryScale.maxMaterializedRows) {
            albums.append(contentsOf: try self.albums(keys: chunk))
        }
        var artists: [Artist] = []
        for chunk in Self.chunks(of: Array(artistList.keys), size: LibraryScale.maxMaterializedRows) {
            artists.append(contentsOf: try self.artists(keys: chunk))
        }
        var byID: [String: Artist] = [:]
        for artist in artists where byID[artist.id] == nil { byID[artist.id] = artist }
        return AlbumArtistIndexBuilder.build(
            albums: albums,
            trackArtists: artists,
            trackArtistsByID: byID,
            configuration: groupingConfiguration.artistNames,
            artistID: { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
        )
    }

    // MARK: - Genres

    /// 可见音乐歌曲的流派,按流派 id 排。结果与流派个数同阶。代表歌曲(`representativeSongIDs`)
    /// 不在这里算,为空。
    ///
    /// 只扫一遍可见歌曲的流派行:计数的同时记下每个流派第一首可见歌曲的行号,写法再按这个行号
    /// 走主键取(一首歌同一流派 id 只有一行,`ordinal` 只是兜底)。不要把写法写回按流派的
    /// 关联子查询:那样每个流派都要把整库可见歌曲再扫一遍(10 万首 46 个流派约 1 s)。
    public func genres() throws -> [LibraryGenre] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                WITH stat AS (
                    SELECT n.genreID AS genreID, min(g.songRowid) AS firstRowid,
                           count(*) AS songCount, count(DISTINCT s.effectiveAlbumRef) AS albumCount
                    FROM songGenre g JOIN genreName n ON n.ref = g.genreRef JOIN song s ON s.rowid = g.songRowid
                    WHERE s.kind = 0 AND s.sourceKey IN (\(Self.enabledSourcesSQL))
                    GROUP BY n.genreID
                )
                SELECT stat.genreID,
                       (SELECT n2.name FROM songGenre g2 CROSS JOIN genreName n2 ON n2.ref = g2.genreRef
                         WHERE g2.songRowid = stat.firstRowid AND n2.genreID = stat.genreID
                         ORDER BY g2.ordinal LIMIT 1),
                       stat.songCount,
                       stat.albumCount
                FROM stat
                ORDER BY stat.genreID COLLATE \(DatabaseCollation.unicodeCompare.name)
                """)
            return rows.map { row in
                LibraryGenre(id: row[0], name: row[1], songCount: row[2], albumCount: row[3], representativeSongIDs: [])
            }
        }
    }

    /// 某流派的可见音乐,库内顺序:同 `LibraryGenreIndexBuilder` 对可见音乐分出的那一组(写入时按
    /// 同一套拆法记进 `songGenre`),走流派表,不逐首解码整库。
    public func genreSongRowList(genreID: String) throws -> LibraryRowList {
        try rowList { _ in
            ("""
             s.rowid IN (SELECT g.songRowid FROM songGenre g JOIN genreName n ON n.ref = g.genreRef WHERE n.genreID = ?)
             AND s.kind = 0 AND s.sourceKey IN (\(Self.enabledSourcesSQL))
             """, [genreID])
        }
    }

    // MARK: - Books, folders, kinds

    /// 一首歌的书(或播客节目)id 与它在书里显示的标题。
    public func bookPlacement(songID: String) throws -> (bookID: String, kind: LibraryCatalogContentKind, displayTitle: String?)? {
        try reader.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.bookID, b.kind, b.displayTitle FROM songBook b JOIN song s ON s.rowid = b.songRowid WHERE s.id = ?
                """, arguments: [songID]) else { return nil }
            return (row[0], LibraryCatalogContentKind(rawValue: row[1]) ?? .spokenWord, row[2])
        }
    }

    /// 这些歌(有声书或播客条目)所在连通块里可见的整首歌,按库内顺序:同一文件夹、同一专辑相连的
    /// 条目一直连下去(`songBook.folderLink` / `albumLink`,与增量归书求的闭包相同)。对它们跑
    /// `SpokenWordBookGrouping` 得到的书,与对整个书架跑的一样(归书只看连通块),所以只要这些书时
    /// 不必读整个书架。结果与连通块同阶。
    public func spokenBookClosureSongs(
        containingSongIDs ids: some Collection<String>,
        kind: LibraryCatalogContentKind = .spokenWord
    ) throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        return try reader.read { db in
            var members = Set<Int64>()
            var folderFrontier = Set<String>()
            var albumFrontier = Set<String>()
            for chunk in Self.chunks(of: Array(ids)) {
                var arguments: StatementArguments = [kind.rawValue]
                arguments += StatementArguments(Array(chunk))
                for row in try Row.fetchAll(db, sql: """
                    SELECT b.songRowid, b.folderLink, b.albumLink FROM songBook b JOIN song s ON s.rowid = b.songRowid
                    WHERE b.kind = ? AND s.id IN (\(Self.placeholders(chunk.count)))
                    """, arguments: arguments) {
                    members.insert(row[0])
                    if let folder: String = row[1] { folderFrontier.insert(folder) }
                    if let album: String = row[2] { albumFrontier.insert(album) }
                }
            }
            var seenFolders = Set<String>()
            var seenAlbums = Set<String>()
            while !folderFrontier.isEmpty || !albumFrontier.isEmpty {
                seenFolders.formUnion(folderFrontier)
                seenAlbums.formUnion(albumFrontier)
                var nextFolders = Set<String>()
                var nextAlbums = Set<String>()
                for (column, links) in [("folderLink", Array(folderFrontier)), ("albumLink", Array(albumFrontier))] {
                    for chunk in Self.chunks(of: links) {
                        var arguments: StatementArguments = [kind.rawValue]
                        arguments += StatementArguments(Array(chunk))
                        for row in try Row.fetchAll(db, sql: """
                            SELECT songRowid, folderLink, albumLink FROM songBook
                            WHERE kind = ? AND \(column) IN (\(Self.placeholders(chunk.count)))
                            """, arguments: arguments) {
                            members.insert(row[0])
                            if let folder: String = row[1], !seenFolders.contains(folder) { nextFolders.insert(folder) }
                            if let album: String = row[2], !seenAlbums.contains(album) { nextAlbums.insert(album) }
                        }
                    }
                }
                folderFrontier = nextFolders
                albumFrontier = nextAlbums
            }
            var decoded: [(rowid: Int64, song: Song)] = []
            for chunk in Self.chunks(of: members.sorted()) {
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom)
                    WHERE song.rowid IN (\(Self.placeholders(chunk.count))) AND source.enabled = 1
                    """, arguments: StatementArguments(Array(chunk)))
                while let row = try rows.next() {
                    decoded.append((row[LibraryCatalogSongCodec.Column.rowid], try LibraryCatalogSongCodec.decode(row)))
                }
            }
            decoded.sort { $0.rowid < $1.rowid }
            return decoded.map(\.song)
        }
    }

    public func bookRowList(bookID: String) throws -> LibraryRowList {
        try rowList { _ in ("s.rowid IN (SELECT songRowid FROM songBook WHERE bookID = ?)", [bookID]) }
    }

    public func contentKind(songID: String) throws -> LibraryCatalogContentKind? {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT kind FROM song WHERE id = ?", arguments: [songID])
                .flatMap(LibraryCatalogContentKind.init(rawValue:))
        }
    }

    public struct FolderEntry: Sendable, Equatable {
        public let key: Int64
        public let path: String
        public let name: String
        public let songCount: Int
    }

    /// 某目录的直接子文件夹(按名字本地化排序)。`path` 为 nil 时给源的根。
    public func folderChildren(sourceID: String, path: String?) throws -> [FolderEntry] {
        try reader.read { db in
            guard let sourceKey = try Int64.fetchOne(db, sql: "SELECT key FROM source WHERE id = ?", arguments: [sourceID]) else {
                return []
            }
            let parentKey: Int64
            if let path {
                guard let key = try Self.folderKey(sourceID: sourceID, path: path, in: db) else { return [] }
                parentKey = key
            } else {
                parentKey = 0
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT key, name, oddPath, songCount FROM folder WHERE sourceKey = ? AND parentKey = ?
                ORDER BY name COLLATE \(LibraryCatalogSchema.localizedStandardCollation) LIMIT \(LibraryScale.maxMaterializedRows)
                """, arguments: [sourceKey, parentKey])
            return rows.map { row in
                let name: String = row[1]
                let odd: String = row[2]
                let childPath = !odd.isEmpty ? odd : (path.map { GroupingMaintenance.joinFolder($0, name) } ?? name)
                return FolderEntry(key: row[0], path: childPath, name: name, songCount: row[3])
            }
        }
    }
}

extension LibraryCatalog {
    /// 可见音乐里带 MV 的歌有几首,同内存里的 `musicVideoSongs.count`(可见集里的音乐、有 MV 路径的那些)。
    /// 读 `flags` 里的 MV 位,不逐首解码;资料库入口与 Mac 侧栏的 MV 计数用它,歌曲模型不在内存里时照样答。
    public func musicVideoSongCount() throws -> Int {
        try reader.read { db in
            let (sql, arguments) = try LibrarySongScope.visibleMusic.whereClause(in: db)
            return try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM song s WHERE \(sql) AND (s.flags & \(LibraryCatalogSongFlags.hasMusicVideo)) != 0",
                arguments: arguments
            ) ?? 0
        }
    }
}
