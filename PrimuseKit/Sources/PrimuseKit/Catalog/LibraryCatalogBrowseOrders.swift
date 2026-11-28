import Foundation
import GRDB

/// 专辑墙、艺人墙在目录上按读音排好的键与分段。与内存里的 `LibraryAlbumBrowseLayoutBuilder`、
/// `LibraryArtistBrowseLayoutBuilder` 同序、同分段(首字母,或按年份排时的年代);
/// 只给键,专辑、艺人按页用 `albums(keys:)` / `artists(keys:)` 物化。
public struct LibraryCatalogBrowseKeys: Sendable, Equatable {
    public let keys: ContiguousArray<Int32>
    public let sections: [LibraryBrowseSection]
    public let revision: Int64

    public init(keys: ContiguousArray<Int32>, sections: [LibraryBrowseSection], revision: Int64) {
        self.keys = keys
        self.sections = sections
        self.revision = revision
    }
}

extension LibraryCatalog {
    /// 专辑墙的 `.artist`、`.title`、`.year` 三种排法;`.recentlyAdded`、`.liked` 不在这里排,返回 nil。
    /// - Parameters:
    ///   - unknownArtistName: 曲库给没有艺术家的专辑填的占位名;按艺术家排时这一组放最后。
    ///   - currentYear: 按年份排时判断年份像不像样(`ReleaseDateBrowseLayoutBuilder.plausibleYear`)。
    ///   - visibleOnly: 只要有可见音乐歌曲的专辑(对应 `visibleAlbums`)。
    public func albumBrowseKeys(
        order: LibraryAlbumBrowseOrder,
        unknownArtistName: String?,
        currentYear: Int,
        visibleOnly: Bool = true
    ) throws -> LibraryCatalogBrowseKeys? {
        // 与内存的比较链一一对应:键比的是首字母桶再比折叠后的文本,BLOB 按字节比正是这个顺序。
        let orderSQL: String
        switch order {
        case .title: orderSQL = "a.titleKey, artistSort, a.id"
        case .artist: orderSQL = "artistSort, a.artistName, yearLast, a.titleKey, a.id"
        case .year: orderSQL = "releaseYear DESC, artistSort, a.titleKey, a.id"
        case .recentlyAdded, .liked: return nil
        }
        let trailing = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.trailingKey)
        return try reader.read { db in
            let revision = try Self.revision(in: db)
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let filter = visibleOnly && splitsLibrary
                ? """
                  WHERE a.key IN (SELECT albumKey FROM albumSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            // 没有艺术家名(键里只有首字母桶那一个字节)或是占位名的,按艺术家比时排在最后。
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT a.key, a.titleKey,
                       CASE WHEN length(a.artistKey) <= 1 OR a.artistName = ? THEN ? ELSE a.artistKey END AS artistSort,
                       CASE WHEN a.year > 0 THEN a.year ELSE \(Int64.max) END AS yearLast,
                       CASE WHEN a.year >= ? AND a.year <= ? THEN a.year ELSE NULL END AS releaseYear
                FROM album a \(filter)
                ORDER BY \(orderSQL)
                """, arguments: [
                    unknownArtistName, trailing,
                    ReleaseDateBrowseLayoutBuilder.earliestPlausibleYear, currentYear + 1,
                ])
            var keys = ContiguousArray<Int32>()
            var buckets: [Int] = []
            var years: [Int?] = []
            while let row = try cursor.next() {
                let key: Int64 = row[0]
                keys.append(try Self.rowid32(key))
                switch order {
                case .title: buckets.append(Self.bucketIndex(of: row[1]))
                case .artist: buckets.append(Self.bucketIndex(of: row[2]))
                case .year, .recentlyAdded, .liked:
                    let year: Int? = row[4]
                    years.append(year)
                }
            }
            let sections = order == .year
                ? LibraryAlbumBrowseLayoutBuilder.eraSections(years, currentYear: currentYear)
                : LibraryBrowseLayout<Album>.sections(bucketIndices: buckets)
            return LibraryCatalogBrowseKeys(keys: keys, sections: sections, revision: revision)
        }
    }

    /// 艺人墙:按名字读音排序并分段,`unknownArtistName` 和没有名字的放最后(对应 `visibleArtists`)。
    public func artistBrowseKeys(unknownArtistName: String?, visibleOnly: Bool = true) throws -> LibraryCatalogBrowseKeys {
        let trailing = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.trailingKey)
        return try reader.read { db in
            let revision = try Self.revision(in: db)
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let filter = visibleOnly && splitsLibrary
                ? """
                  WHERE artist.key IN (SELECT artistRef FROM artistSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT artist.key,
                       CASE WHEN length(artist.nameKey) <= 1 OR artist.name = ? THEN ? ELSE artist.nameKey END AS nameSort
                FROM artist \(filter)
                ORDER BY nameSort, artist.name, artist.id
                """, arguments: [unknownArtistName, trailing])
            var keys = ContiguousArray<Int32>()
            var buckets: [Int] = []
            while let row = try cursor.next() {
                let key: Int64 = row[0]
                keys.append(try Self.rowid32(key))
                buckets.append(Self.bucketIndex(of: row[1]))
            }
            return LibraryCatalogBrowseKeys(
                keys: keys,
                sections: LibraryBrowseLayout<Artist>.sections(bucketIndices: buckets),
                revision: revision
            )
        }
    }

    /// 流派卡片的代表歌曲,每个流派最多 `limit` 首。与 `LibraryGenreIndexBuilder` 同一套挑法:
    /// 按排名(有封面在前、年份新的在前、再按 id)先取不同专辑各自最靠前的一首,不够再按排名补。
    /// 只看可见的音乐歌曲(与 `genres()` 同一个范围);`genreIDs` 为 nil 时给全部流派。
    /// 主线程外调用:按流派、排名流式走一遍流派成员。
    public func genreRepresentativeSongIDs(genreIDs: Set<String>? = nil, limit: Int = 3) throws -> [String: [String]] {
        guard limit > 0 else { return [:] }
        var filter = ""
        var arguments = StatementArguments()
        if let genreIDs {
            guard !genreIDs.isEmpty else { return [:] }
            filter = "AND n.genreID IN (\(Array(repeating: "?", count: genreIDs.count).joined(separator: ",")))"
            arguments = StatementArguments(genreIDs.sorted())
        }
        return try reader.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT n.genreID, s.id, s.albumID
                FROM songGenre g JOIN genreName n ON n.ref = g.genreRef JOIN song s ON s.rowid = g.songRowid
                WHERE s.kind = 0 AND s.sourceKey IN (\(Self.enabledSourcesSQL)) \(filter)
                ORDER BY n.genreID,
                         (s.coverArtFileName IS NOT NULL AND s.coverArtFileName <> '') DESC,
                         s.year IS NULL, s.year DESC, s.id
                """, arguments: arguments)
            var result: [String: [String]] = [:]
            var genre: String?
            var albumBests: [String] = []
            var seenAlbums: Set<String> = []
            // 补位只会用到排名前 2 × limit 首里的(已选的至多 limit 首)。
            var ranked: [String] = []
            func finish() {
                guard let genre else { return }
                var selected = albumBests
                for id in ranked where selected.count < limit && !selected.contains(id) { selected.append(id) }
                result[genre] = selected
            }
            while let row = try cursor.next() {
                let genreID: String = row[0]
                if genreID != genre {
                    finish()
                    genre = genreID
                    albumBests = []
                    seenAlbums = []
                    ranked = []
                }
                let songID: String = row[1]
                if ranked.count < limit * 2, !ranked.contains(songID) { ranked.append(songID) }
                guard albumBests.count < limit else { continue }
                let albumID = (row[2] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !albumID.isEmpty, seenAlbums.insert(albumID).inserted, !albumBests.contains(songID) {
                    albumBests.append(songID)
                }
            }
            finish()
            return result
        }
    }

    /// 专辑 id → 专辑键(电视墙找回记住的那一张)。没有这张专辑时为 nil。
    public func albumKey(id: String) throws -> Int32? {
        try reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT key FROM album WHERE id = ?", arguments: [id]).map(Self.rowid32)
        }
    }

    /// 艺人 id → 艺人键。没有这位艺人时为 nil。
    public func artistKey(id: String) throws -> Int32? {
        try reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT key FROM artist WHERE id = ? LIMIT 1", arguments: [id]).map(Self.rowid32)
        }
    }

    /// 歌曲 id → 行号。没有这首歌时为 nil。
    public func songRowid(id: String) throws -> Int32? {
        try reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM song WHERE id = ?", arguments: [id]).map(Self.rowid32)
        }
    }

    /// 一页行号对应的歌曲 id,与输入一一对应;已删掉的行为 nil(电视「歌曲」页按页取条目)。
    public func songIDs(atRowids rowids: [Int32]) throws -> [String?] {
        guard !rowids.isEmpty else { return [] }
        var byRowid: [Int32: String] = [:]
        byRowid.reserveCapacity(rowids.count)
        try reader.read { db in
            for chunk in Self.chunks(of: rowids) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT rowid, id FROM song WHERE rowid IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    byRowid[try Self.rowid32(row[0])] = row[1]
                }
            }
        }
        return rowids.map { byRowid[$0] }
    }

    /// 一页行号对应的歌曲的专辑 id(歌曲行上记的原样),与输入一一对应;已删掉的行、没有专辑的为 nil。
    /// 只读一列,不解码整首歌(按流派列专辑用)。
    public func albumIDs(atRowids rowids: [Int32]) throws -> [String?] {
        guard !rowids.isEmpty else { return [] }
        var byRowid: [Int32: String] = [:]
        byRowid.reserveCapacity(rowids.count)
        try reader.read { db in
            for chunk in Self.chunks(of: rowids) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT rowid, albumID FROM song WHERE rowid IN (\(Self.placeholders(chunk.count))) AND albumID IS NOT NULL",
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    byRowid[try Self.rowid32(row[0])] = row[1]
                }
            }
        }
        return rowids.map { byRowid[$0] }
    }

    // MARK: - CarPlay lists

    /// 车机歌曲列表:按标题(Foundation 的 `localizedCaseInsensitiveCompare`)排的前 `limit` 首,
    /// 同名保持库内顺序 —— 与在内存数组上跑 `CarPlayListSelection.firstSorted` 的结果一样。
    public func firstSongsByTitle(_ scope: LibrarySongScope = .visibleMusic, limit: Int) throws -> [Song] {
        let cap = LibraryScaleGuard.admitMaterialization(count: limit)
        guard cap > 0 else { return [] }
        let rowids = try reader.read { db -> [Int32] in
            let (scopeSQL, arguments) = try scope.whereClause(in: db)
            return try Int64.fetchAll(db, sql: """
                SELECT s.rowid FROM song s WHERE \(scopeSQL)
                ORDER BY s.title COLLATE \(DatabaseCollation.localizedCaseInsensitiveCompare.name), s.rowid
                LIMIT \(cap)
                """, arguments: arguments).map(Self.rowid32)
        }
        return try songs(rowids: rowids)
    }

    /// 车机专辑列表:可见专辑按标题(`localizedCaseInsensitiveCompare`)排的前 `limit` 张,同名保持
    /// 专辑墙的先后(标题本地化排序、同名按首次出现)。
    public func firstAlbumsByTitle(limit: Int) throws -> [Album] {
        let cap = LibraryScaleGuard.admitMaterialization(count: limit)
        guard cap > 0 else { return [] }
        let keys = try reader.read { db -> [Int32] in
            let filter = try Self.visibleSplitsLibrary(in: db)
                ? """
                  WHERE a.key IN (SELECT albumKey FROM albumSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            return try Int64.fetchAll(db, sql: """
                SELECT a.key FROM album a \(filter)
                ORDER BY a.title COLLATE \(DatabaseCollation.localizedCaseInsensitiveCompare.name),
                         a.title COLLATE \(LibraryCatalogSchema.localizedCollation), a.firstRowid
                LIMIT \(cap)
                """).map(Self.rowid32)
        }
        return try albums(keys: keys, visibleCounts: true)
    }

    /// 车机艺人列表(「全部艺术家」):可见艺人按名字(`localizedCaseInsensitiveCompare`)排的前 `limit` 位,
    /// 同名保持艺人列表的先后。
    public func firstArtistsByName(limit: Int) throws -> [Artist] {
        let cap = LibraryScaleGuard.admitMaterialization(count: limit)
        guard cap > 0 else { return [] }
        let keys = try reader.read { db -> [Int32] in
            let filter = try Self.visibleSplitsLibrary(in: db)
                ? """
                  WHERE artist.key IN (SELECT artistRef FROM artistSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            return try Int64.fetchAll(db, sql: """
                SELECT artist.key FROM artist \(filter)
                ORDER BY artist.name COLLATE \(DatabaseCollation.localizedCaseInsensitiveCompare.name),
                         artist.name COLLATE \(LibraryCatalogSchema.localizedCollation), artist.firstRowid, artist.firstOrdinal
                LIMIT \(cap)
                """).map(Self.rowid32)
        }
        return try artists(keys: keys, visibleCounts: true)
    }

    /// 排序键的第一个字节是首字母桶(0–25 是 A–Z,26 是 "#")。
    static func bucketIndex(of key: Data) -> Int {
        guard let first = key.first else { return LibraryCollationPolicy.letterBuckets.count }
        return min(Int(first), LibraryCollationPolicy.letterBuckets.count)
    }
}
