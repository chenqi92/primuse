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

    /// 可见专辑里按 id 取一批(`visibleAlbum(id:)` 的批量形式):保持给的先后,没有的、没有可见音乐的不给。
    /// 至多 `LibraryScale.maxMaterializedRows` 个 id。
    public func albums(visibleIDs ids: some Collection<String>) throws -> [Album] {
        let requested = Array(ids.prefix(LibraryScaleGuard.admitMaterialization(count: ids.count)))
        guard !requested.isEmpty else { return [] }
        return try reader.read { db in
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? " AND key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            var keyByID: [String: Int32] = [:]
            for chunk in Self.chunks(of: Array(Set(requested))) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, key FROM album WHERE id IN (\(Self.placeholders(chunk.count)))\(filter)
                    """, arguments: StatementArguments(Array(chunk)))
                for row in rows { keyByID[row[0]] = try Self.rowid32(row[1]) }
            }
            var seen = Set<String>()
            let keys = requested.compactMap { id in seen.insert(id).inserted ? keyByID[id] : nil }
            return try Self.fetchAlbums(keys: keys, splits: splits, in: db)
        }
    }

    /// 标题可能与 `title` 相同(不分大小写、去掉首尾空白)的可见专辑,按专辑墙的先后(`albumKeys`)。
    /// 用排序键 `titleKey` 圈候选:不分大小写相同的两个标题排序键也相同(键再宽一些,不分变音、全半角,
    /// 只看前 24 个码位),所以这里给的是一个超集,调用方再按自己的规则逐个比。整张专辑表比一列二进制,
    /// 不回调 Swift。
    public func visibleAlbumCandidates(titled title: String) throws -> [Album] {
        let key = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: title))
        return try reader.read { db in
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? " AND key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            let keys = try Int64.fetchAll(db, sql: """
                SELECT key FROM album WHERE titleKey = ?\(filter)
                ORDER BY title COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid
                """, arguments: [key])
            let admitted = keys.prefix(LibraryScaleGuard.admitMaterialization(count: keys.count))
            return try Self.fetchAlbums(keys: try admitted.map(Self.rowid32), splits: splits, in: db)
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

    /// 「专辑艺术家」列表里的一位,与 `albumArtistIndexForReference()` 里这个 id 的那一项相同(不在列表里时 nil):
    /// 同是可见曲目艺人时是那位曲目艺人、专辑数换成署名给他的可见专辑数;只当过专辑艺人的(「群星」)
    /// 名字取专辑墙上第一张署名给他、带名字的专辑上的写法,歌曲数是这些专辑的可见歌曲数之和。
    /// 署名按 `AlbumArtistCreditPolicy.resolvedCredits` 现算(与参照实现同一条规则),候选专辑是专辑艺人就是他的、
    /// 存着的署名里有他的,以及名字里带「 • 」的(那一支要看各段是不是可见曲目艺人),结果与这几张专辑同阶。
    public func visibleAlbumArtist(id: String) throws -> Artist? {
        try reader.read { db in
            guard let ref = try Int64.fetchOne(db, sql: "SELECT ref FROM artistRef WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let splits = try Self.visibleSplitsLibrary(in: db)
            let albumFilter = splits
                ? " AND key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            let keys = try Int64.fetchAll(db, sql: """
                SELECT key FROM album
                WHERE (artistRef = ?1 OR key IN (SELECT albumKey FROM albumArtistCredit WHERE artistRef = ?1)
                       OR artistName LIKE '% • %')\(albumFilter)
                ORDER BY title COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid
                """, arguments: [ref])
            let albums = try Self.fetchAlbums(keys: try keys.map(Self.rowid32), splits: splits, in: db)
            var trackArtists: [String: Artist?] = [:]
            func trackArtist(_ artistID: String) throws -> Artist? {
                if let known = trackArtists[artistID] { return known }
                let artist = try Self.visibleTrackArtist(id: artistID, splits: splits, in: db)
                trackArtists[artistID] = .some(artist)
                return artist
            }
            let configuration = groupingConfiguration.artistNames.normalized()
            var albumCount = 0
            var songCount = 0
            var albumOnlyName: String?
            var lookupError: Error?
            for album in albums {
                let credits = AlbumArtistCreditPolicy.resolvedCredits(
                    for: album,
                    configuration: configuration,
                    isKnownTrackArtist: { candidate in
                        do { return try trackArtist(candidate) != nil } catch { lookupError = error; return false }
                    },
                    knownTrackArtistName: { candidate in (try? trackArtist(candidate))?.name },
                    artistID: { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
                )
                if let lookupError { throw lookupError }
                guard let credit = credits.first(where: { $0.id == id }) else { continue }
                albumCount += 1
                songCount += album.songCount
                if albumOnlyName == nil, let name = credit.name { albumOnlyName = name }
            }
            guard albumCount > 0 else { return nil }
            if var shared = try trackArtist(id) {
                shared.albumCount = albumCount
                return shared
            }
            guard let albumOnlyName else { return nil }
            return Artist(id: id, name: albumOnlyName, albumCount: albumCount, songCount: songCount)
        }
    }

    /// 可见曲目艺人里的这一位(`visibleArtist(id:)` 在同一个读里)。
    private static func visibleTrackArtist(id: String, splits: Bool, in db: Database) throws -> Artist? {
        let filter = splits
            ? " AND key IN (SELECT artistRef FROM artistSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
            : ""
        guard let key = try Int64.fetchOne(db, sql: """
            SELECT key FROM artist WHERE key = (SELECT ref FROM artistRef WHERE id = ?)\(filter)
            """, arguments: [id]) else { return nil }
        return try fetchArtists(keys: [try rowid32(key)], splits: splits, in: db).first
    }

    /// 名字可能与 `name` 相同(不分大小写)的可见艺人,按艺人列表的先后(`artistKeys`)。同
    /// `visibleAlbumCandidates(titled:)`:按排序键 `nameKey` 圈出的超集,调用方再逐个比。
    public func visibleArtistCandidates(named name: String) throws -> [Artist] {
        let key = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: name))
        return try reader.read { db in
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? " AND key IN (SELECT artistRef FROM artistSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : ""
            let keys = try Int64.fetchAll(db, sql: """
                SELECT key FROM artist WHERE nameKey = ?\(filter)
                ORDER BY name COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid, firstOrdinal
                """, arguments: [key])
            let admitted = keys.prefix(LibraryScaleGuard.admitMaterialization(count: keys.count))
            return try Self.fetchArtists(keys: try admitted.map(Self.rowid32), splits: splits, in: db)
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

    /// 本机播客有几档节目(可见的播客单集分到的节目 id 有几个),同内存里的 `localPodcastShowCount`。
    public func podcastShowCount() throws -> Int {
        try reader.read { db in
            let (sql, arguments) = try LibrarySongScope(kinds: [.podcast]).whereClause(in: db)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT count(DISTINCT b.bookID) FROM song s JOIN songBook b ON b.songRowid = s.rowid
                    WHERE \(sql) AND b.kind = \(LibraryCatalogContentKind.podcast.rawValue) AND b.bookID IS NOT NULL
                    """,
                arguments: arguments
            ) ?? 0
        }
    }

    /// 有声书有几本、几章(同内存里的 `spokenWordBookCount` / `spokenWordChapterCount`):本数是可见有声条目分到的书
    /// id 有几个,章数按 `SpokenWordChapterTally`(带内嵌章节的文件按章节数,其余一个文件一章)。
    public func spokenWordTotals() throws -> (books: Int, chapters: Int) {
        try reader.read { db in
            let (sql, arguments) = try LibrarySongScope(kinds: [.spokenWord]).whereClause(in: db)
            let books = try Int.fetchOne(
                db,
                sql: """
                    SELECT count(DISTINCT b.bookID) FROM song s JOIN songBook b ON b.songRowid = s.rowid
                    WHERE \(sql) AND b.kind = \(LibraryCatalogContentKind.spokenWord.rawValue) AND b.bookID IS NOT NULL
                    """,
                arguments: arguments
            ) ?? 0
            var chapters = 0
            let rows = try Row.fetchCursor(db, sql: "SELECT s.extra FROM song s WHERE \(sql)", arguments: arguments)
            while let row = try rows.next() {
                var embedded: Int?
                if let blob = row.dataNoCopy(atIndex: 0) {
                    var extra = ExtraReader(blob)
                    var strings: [Int: String] = [:]
                    var doubles: [Int: UInt64] = [:]
                    var rare = LibraryCatalogSongCodec.RareFields()
                    try LibraryCatalogSongCodec.decodeRareFields(&extra, into: &rare, strings: &strings, doubles: &doubles)
                    embedded = rare.contentMetadata?.embeddedChapterCount
                }
                chapters += SpokenWordChapterTally.chapters(embeddedChapterCount: embedded)
            }
            return (books, chapters)
        }
    }

    /// 一个范围里按库内顺序的头几首的 id(资料库入口上 MV、有声书、环境音那几张小封面,同数组的 `prefix`)。
    public func firstSongIDs(_ scope: LibrarySongScope, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            return try String.fetchAll(
                db, sql: "SELECT s.id FROM song s WHERE \(sql) ORDER BY s.rowid LIMIT \(limit)", arguments: arguments
            )
        }
    }

    /// 这些 id 里本机播客单集各在哪个节目里(节目 id 与节目名),同内存里 `localPodcastBookIDs` 与
    /// `localPodcastShowTitle(forSongID:)`。不是播客单集的 id 不在结果里。按 id 分批查,不逐首解码。
    public func podcastShowPlacements(songIDs: some Collection<String>) throws -> [String: LibraryCatalogShowPlacement] {
        let requested = Array(Set(songIDs))
        guard !requested.isEmpty else { return [:] }
        return try reader.read { db in
            var placements: [String: LibraryCatalogShowPlacement] = [:]
            for chunk in Self.chunks(of: requested) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT s.id, b.bookID, k.title FROM song s
                        JOIN songBook b ON b.songRowid = s.rowid
                        LEFT JOIN book k ON k.id = b.bookID AND k.kind = b.kind
                        WHERE s.id IN (\(Self.placeholders(chunk.count)))
                          AND b.kind = \(LibraryCatalogContentKind.podcast.rawValue) AND b.bookID IS NOT NULL
                        """,
                    arguments: StatementArguments(Array(chunk))
                )
                while let row = try rows.next() {
                    placements[row[0]] = LibraryCatalogShowPlacement(showID: row[1], title: row[2])
                }
            }
            return placements
        }
    }

    /// 可见音乐里带 MV 的歌作挑选候选(id、艺人、加入时间),按库内顺序 —— 同内存里 `musicVideoSongs` 的那些与先后。
    /// 读 `flags` 里的 MV 位与三列,不逐首解码。
    public func musicVideoCandidates() throws -> [MusicVideoRecommendationPolicy.Candidate] {
        try reader.read { db in
            let (sql, arguments) = try LibrarySongScope.visibleMusic.whereClause(in: db)
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.id, s.artistID, s.dateAdded FROM song s
                    WHERE \(sql) AND (s.flags & \(LibraryCatalogSongFlags.hasMusicVideo)) != 0
                    ORDER BY s.rowid
                    """,
                arguments: arguments
            )
            var candidates: [MusicVideoRecommendationPolicy.Candidate] = []
            while let row = try rows.next() {
                candidates.append(MusicVideoRecommendationPolicy.Candidate(
                    id: row[0], artistID: row[1], dateAdded: Date(timeIntervalSinceReferenceDate: row[2])
                ))
            }
            return candidates
        }
    }

    /// 可见音乐里带 MV 的歌的行号,按库内顺序 —— 同内存里 `musicVideoSongs` 的那些与先后(S5b,MV 页)。
    /// 读 `flags` 里的 MV 位,不逐首解码;调用方在一次物化的上限内取歌,再照页面的排序排。
    public func musicVideoRowList() throws -> LibraryRowList {
        try rowList { db in
            let (sql, arguments) = try LibrarySongScope.visibleMusic.whereClause(in: db)
            return ("\(sql) AND (s.flags & \(LibraryCatalogSongFlags.hasMusicVideo)) != 0", arguments)
        }
    }

    /// 打着「用户编辑」标记(`userMetadataEditedAt` 不为空)的歌的 id,含停用源、所有类别,
    /// 同 `songs.filter { $0.userMetadataEditedAt != nil }` 的那些 id。读 `flags` 里的标记位,不逐首解码。
    public func userEditedSongIDs() throws -> Set<String> {
        try reader.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT id FROM song WHERE (flags & \(LibraryCatalogSongFlags.userEdited)) != 0"
            ))
        }
    }

    /// 这个源里有没有时长还没读出来(不大于 0)的歌(含停用源、所有类别),
    /// 同 `songs.contains { $0.sourceID == sourceID && $0.duration <= 0 }`。按源的索引查,找到一首就停。
    public func hasSongsWithoutDuration(sourceID: String) throws -> Bool {
        try reader.read { db in
            let (sql, arguments) = try LibrarySongScope(sourceID: sourceID, includesDisabledSources: true).whereClause(in: db)
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM song s WHERE \(sql) AND s.duration <= 0)",
                arguments: arguments
            ) ?? false
        }
    }

    /// 这些专辑 id 里还有歌的那些(任一源、任一类别,含停用源),同 `songs.contains { $0.albumID == id }`。
    public func albumIDsWithSongs(among albumIDs: some Collection<String>) throws -> Set<String> {
        let requested = Array(Set(albumIDs))
        guard !requested.isEmpty else { return [] }
        return try reader.read { db in
            var found = Set<String>()
            for chunk in Self.chunks(of: requested) {
                found.formUnion(try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT albumID FROM song WHERE albumID IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(Array(chunk))
                ))
            }
            return found
        }
    }
}

/// 一首本机播客单集所在的节目(`podcastShowPlacements`)。
public struct LibraryCatalogShowPlacement: Sendable, Equatable {
    public let showID: String
    public let title: String?

    public init(showID: String, title: String?) {
        self.showID = showID
        self.title = title
    }
}

/// 资料库入口挑封面预览时一首歌要的几样(Q2,6c 单元 4 U3b),按 `decode(_:)` 的规则读(extra 的覆盖值优先)。
public struct LibraryArtworkPreviewSongRow: Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let albumID: String?
    public let artistID: String?
    public let coverArtFileName: String?
    public let filePath: String
}

extension LibraryCatalog {
    /// 范围里的歌按库内顺序逐首交出预览挑选要的几样,不整首解码(资料库入口在歌曲模型不在内存里时挑封面用)。
    public func forEachArtworkPreviewSong(
        _ scope: LibrarySongScope, _ body: (LibraryArtworkPreviewSongRow) throws -> Void
    ) throws {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.id, source.id, s.albumID, s.artistID, s.coverArtFileName, s.filePath, s.extra
                    FROM song s JOIN source ON source.key = s.sourceKey
                    WHERE \(sql) ORDER BY s.rowid
                    """,
                arguments: arguments
            )
            while let row = try rows.next() {
                var strings: [Int: String] = [:]
                if let blob = row.dataNoCopy(atIndex: 6) {
                    var extra = ExtraReader(blob)
                    var doubles: [Int: UInt64] = [:]
                    var rare = LibraryCatalogSongCodec.RareFields()
                    try LibraryCatalogSongCodec.decodeRareFields(&extra, into: &rare, strings: &strings, doubles: &doubles)
                }
                guard let id = strings[LibraryCatalogSongCodec.Column.id] ?? (row[0] as String?),
                      let filePath = strings[LibraryCatalogSongCodec.Column.filePath] ?? (row[5] as String?) else { continue }
                try body(LibraryArtworkPreviewSongRow(
                    id: id, sourceID: row[1],
                    albumID: strings[LibraryCatalogSongCodec.Column.albumID] ?? row[2],
                    artistID: strings[LibraryCatalogSongCodec.Column.artistID] ?? row[3],
                    coverArtFileName: strings[LibraryCatalogSongCodec.Column.coverArtFileName] ?? row[4],
                    filePath: filePath
                ))
            }
        }
    }

    /// 这些专辑键对应的专辑 id(保持顺序,跳过不在的)。
    public func albumIDs(keys: some Collection<Int32>) throws -> [(key: Int32, id: String)] {
        try keyedRows(table: "album", extraColumn: nil, keys: keys).map { (key: $0.key, id: $0.id) }
    }

    /// 这些艺人键对应的艺人 id 与头像路径(保持顺序,跳过不在的)。
    public func artistIDsAndThumbnails(keys: some Collection<Int32>) throws -> [(key: Int32, id: String, thumbnailPath: String?)] {
        try keyedRows(table: "artist", extraColumn: "thumbnailPath", keys: keys)
    }

    private func keyedRows(
        table: String, extraColumn: String?, keys: some Collection<Int32>
    ) throws -> [(key: Int32, id: String, thumbnailPath: String?)] {
        let ordered = Array(keys)
        guard !ordered.isEmpty else { return [] }
        return try reader.read { db in
            var byKey: [Int32: (String, String?)] = [:]
            byKey.reserveCapacity(ordered.count)
            for chunk in Self.chunks(of: ordered) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT key, id, \(extraColumn ?? "NULL") FROM \(table) WHERE key IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    let key: Int64 = row[0]
                    byKey[Int32(truncatingIfNeeded: key)] = (row[1], row[2])
                }
            }
            return ordered.compactMap { key in byKey[key].map { (key: key, id: $0.0, thumbnailPath: $0.1) } }
        }
    }
}
