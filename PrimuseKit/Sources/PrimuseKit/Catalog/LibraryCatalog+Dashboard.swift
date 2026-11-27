import Foundation
import GRDB

/// 一个范围里歌曲的几项统计(Mac 首页的资料库健康度与主卡):首数、可播放的、总时长、带封面引用的、
/// 带歌词文件引用的。口径与逐首数内存里的歌相同:时长按 `max(0, duration)` 加(`durationKey`),
/// 可播放、有封面、有歌词文件读写入时算好的标志位(`LibraryCatalogSongFlags`)。
public struct LibraryCatalogSongStatistics: Sendable, Equatable {
    public var count: Int
    public var playableCount: Int
    public var totalDuration: Double
    public var withCoverCount: Int
    public var withLyricsFileCount: Int

    public init(count: Int = 0, playableCount: Int = 0, totalDuration: Double = 0,
                withCoverCount: Int = 0, withLyricsFileCount: Int = 0) {
        self.count = count
        self.playableCount = playableCount
        self.totalDuration = totalDuration
        self.withCoverCount = withCoverCount
        self.withLyricsFileCount = withLyricsFileCount
    }
}

/// 「最近添加」的专辑:前 `limit` 张的键与 id(按顺序),以及一共有几张。
public struct LibraryCatalogRecentlyAddedAlbums: Sendable, Equatable {
    public var keys: [Int32]
    public var ids: [String]
    public var total: Int
    public var revision: Int64

    public init(keys: [Int32], ids: [String], total: Int, revision: Int64) {
        self.keys = keys
        self.ids = ids
        self.total = total
        self.revision = revision
    }
}

extension LibraryCatalog {
    /// 范围里歌曲的统计,一句聚合,不物化歌曲。
    public func songStatistics(_ scope: LibrarySongScope) throws -> LibraryCatalogSongStatistics {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT count(*),
                           total((s.flags & \(LibraryCatalogSongFlags.playable)) != 0),
                           total(s.durationKey),
                           total((s.flags & \(LibraryCatalogSongFlags.hasCover)) != 0),
                           total((s.flags & \(LibraryCatalogSongFlags.hasLyricsFile)) != 0)
                    FROM song s WHERE \(sql)
                    """,
                arguments: arguments
            ) else { return LibraryCatalogSongStatistics() }
            let playable: Double = row[1]
            let cover: Double = row[3]
            let lyrics: Double = row[4]
            return LibraryCatalogSongStatistics(
                count: row[0], playableCount: Int(playable), totalDuration: row[2],
                withCoverCount: Int(cover), withLyricsFileCount: Int(lyrics)
            )
        }
    }

    /// 范围里最新加入的 `limit` 首的行号:按 `dateAdded` 从新到旧,加入时间相同的保持库内顺序
    /// (与对库内顺序的歌做稳定排序 `sorted { $0.dateAdded > $1.dateAdded }` 的前 `limit` 首相同;
    /// 歌曲列表的「加入时间」降序把同一时间的行倒过来排,不是这个顺序)。
    public func newestSongRowList(_ scope: LibrarySongScope, limit: Int) throws -> LibraryRowList {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        return try rowList(orderBy: "s.dateAdded DESC, s.rowid ASC", limit: cap) { db in try scope.whereClause(in: db) }
    }

    /// Mac 首页「最近添加」的专辑顺序(`RecentlyAddedAlbumPolicy.Index`,每首歌按自己的 `dateAdded`):
    /// 可见专辑按其中可见音乐歌曲(按歌曲的 `albumID` 归到专辑)最新的加入时间从新到旧,时间相同按专辑 id;
    /// 没有这样的歌的专辑排在最后,按专辑 id。`includingExternalSongs` 为 false 时外部条目
    /// (`Song.isExternal`)不算加入时间,只有外部条目的专辑不列。返回前 `limit` 张与总张数。
    public func recentlyAddedAlbumKeys(includingExternalSongs: Bool, limit: Int) throws -> LibraryCatalogRecentlyAddedAlbums {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        return try reader.read { db in
            let revision = try Self.revision(in: db)
            let (songWhere, songArguments) = try LibrarySongScope.visibleMusic.whereClause(in: db)
            let external = LibraryCatalogSongFlags.external
            let visibleFilter = try Self.visibleSplitsLibrary(in: db)
                ? "a.key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))"
                : "1"
            var arguments = StatementArguments([includingExternalSongs ? 1 : 0])
            arguments += songArguments
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    WITH dated AS (
                        SELECT s.albumID AS albumID,
                               max(CASE WHEN ? = 1 OR (s.flags & \(external)) = 0 THEN s.dateAdded END) AS latest,
                               max((s.flags & \(external)) != 0) AS hasExternal
                        FROM song s
                        WHERE \(songWhere) AND s.albumID IS NOT NULL AND s.albumID != ''
                        GROUP BY s.albumID
                    )
                    SELECT a.key, a.id FROM album a LEFT JOIN dated d ON d.albumID = a.id
                    WHERE \(visibleFilter) AND NOT (d.latest IS NULL AND coalesce(d.hasExternal, 0) = 1)
                    ORDER BY d.latest IS NULL, d.latest DESC, a.id COLLATE \(DatabaseCollation.unicodeCompare.name)
                    """,
                arguments: arguments
            )
            var keys: [Int32] = []
            var ids: [String] = []
            var total = 0
            while let row = try cursor.next() {
                total += 1
                guard keys.count < cap else { continue }
                let key: Int64 = row[0]
                keys.append(try Self.rowid32(key))
                ids.append(row[1])
            }
            return LibraryCatalogRecentlyAddedAlbums(keys: keys, ids: ids, total: total, revision: revision)
        }
    }
}
