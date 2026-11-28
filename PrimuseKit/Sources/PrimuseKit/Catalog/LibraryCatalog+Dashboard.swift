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
}
