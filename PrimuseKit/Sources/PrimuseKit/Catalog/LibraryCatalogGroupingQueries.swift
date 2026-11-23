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
    static func visibleSplitsLibrary(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM source WHERE enabled = 0)
                OR EXISTS (SELECT 1 FROM song WHERE kind != 0 AND sourceKey IN (\(enabledSourcesSQL)))
            """) ?? false
    }

    // MARK: - Albums

    /// 专辑按标题本地化排序、同名按首次出现的先后(与参照实现的稳定排序一致)。
    /// `visibleOnly` 只要有可见音乐歌曲的专辑。
    public func albumKeys(visibleOnly: Bool = true) throws -> LibraryCatalogKeyList {
        try pool.read { db in
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
        return try pool.read { db in
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let splits = visibleCounts && splitsLibrary
            var byKey: [Int32: Album] = [:]
            for chunk in Self.chunks(of: admitted) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT a.key, a.id, a.title, a.artistID, a.artistName, a.year, a.genre, a.songCount, a.duration,
                           a.sourceID,
                           (SELECT total(songCount) FROM albumSourceStat st
                               WHERE st.albumKey = a.key AND st.sourceKey IN (\(Self.enabledSourcesSQL))),
                           (SELECT total(duration) FROM albumSourceStat st
                               WHERE st.albumKey = a.key AND st.sourceKey IN (\(Self.enabledSourcesSQL)))
                    FROM album a WHERE a.key IN (\(Self.placeholders(chunk.count)))
                    """, arguments: StatementArguments(chunk.map(Int64.init)))
                for row in rows {
                    let key = try Self.rowid32(row[0])
                    let visibleCount: Double = row[10]
                    let visibleDuration: Double = row[11]
                    byKey[key] = Album(
                        id: row[1], title: row[2], artistID: row[3], artistName: row[4], year: row[5], genre: row[6],
                        songCount: splits ? Int(visibleCount) : row[7],
                        totalDuration: splits ? visibleDuration : row[8],
                        sourceID: row[9]
                    )
                }
            }
            return admitted.compactMap { byKey[$0] }
        }
    }

    /// 专辑的可见歌曲,按碟号、曲号、标题(`AlbumTrackOrder`)。
    public func albumSongRowList(albumID: String) throws -> LibraryRowList {
        try rowList(orderBy: "s.discKey, s.trackKey, s.title COLLATE \(LibraryCatalogSchema.localizedStandardCollation), s.id") { _ in
            ("s.effectiveAlbumRef = (SELECT key FROM album WHERE id = ?) AND s.sourceKey IN (\(Self.enabledSourcesSQL))", [albumID])
        }
    }

    /// 专辑封面回退用的那首:有封面的优先,再按碟号、曲号、id(可见歌曲,所有类别)。
    public func preferredArtworkSongID(albumID: String) throws -> String? {
        try pool.read { db in
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
        try pool.read { db in
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
        return try pool.read { db in
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let splits = visibleCounts && splitsLibrary
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
        try pool.read { db in
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
        try pool.read { db in
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

    // MARK: - Books, folders, kinds

    /// 一首歌的书(或播客节目)id 与它在书里显示的标题。
    public func bookPlacement(songID: String) throws -> (bookID: String, kind: LibraryCatalogContentKind, displayTitle: String?)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.bookID, b.kind, b.displayTitle FROM songBook b JOIN song s ON s.rowid = b.songRowid WHERE s.id = ?
                """, arguments: [songID]) else { return nil }
            return (row[0], LibraryCatalogContentKind(rawValue: row[1]) ?? .spokenWord, row[2])
        }
    }

    public func bookRowList(bookID: String) throws -> LibraryRowList {
        try rowList { _ in ("s.rowid IN (SELECT songRowid FROM songBook WHERE bookID = ?)", [bookID]) }
    }

    public func contentKind(songID: String) throws -> LibraryCatalogContentKind? {
        try pool.read { db in
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
        try pool.read { db in
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
