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
        return try pool.read { db in
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
        return try pool.read { db in
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

    /// 排序键的第一个字节是首字母桶(0–25 是 A–Z,26 是 "#")。
    static func bucketIndex(of key: Data) -> Int {
        guard let first = key.first else { return LibraryCollationPolicy.letterBuckets.count }
        return min(Int(first), LibraryCollationPolicy.letterBuckets.count)
    }
}
