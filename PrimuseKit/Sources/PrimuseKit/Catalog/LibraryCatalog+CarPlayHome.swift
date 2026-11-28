import Foundation
import GRDB

/// 车机首页「最近添加」那一块在目录上的答案(C2),与 App 里 `CarPlayEditorCatalog.project` 在内存里算的同一套规则:
/// - `songIDs`:范围里的歌按自己的加入时间(`dateAdded`)从新到旧、同时间按 id 的前 `songLimit` 首(「最近添加的歌」)。
/// - `albums`:首页认的专辑(可见、id 不空、标题去掉空白后不空),时间是范围里归到它(歌的 `albumID`)的歌按
///   `RecentlyAddedAlbumPolicy.date(for:)` 算的加入时间里最新的;没有这样的歌的专辑不列。从新到旧、同时间按 id 的前
///   `albumLimit` 张。
/// - `singles`:范围里不归到首页认的专辑的歌(没有专辑、专辑没有标题),按同一个加入时间从新到旧、同时间按 id 的前
///   `singleLimit` 首。
/// 首页最后把专辑与单曲合起来再挑前几项;两边各取前几项再合,与在整份上挑相同。
public struct LibraryCarPlayRecentlyAdded: Sendable, Equatable {
    public struct Album: Sendable, Equatable {
        public let key: Int32
        public let id: String
        public let date: Double
    }

    public struct Single: Sendable, Equatable {
        public let id: String
        public let date: Double
    }

    // crash-pattern: allow song-id-collection-property 至多 songLimit 个(车机首页取 100)
    public var songIDs: [String] = []
    public var albums: [Album] = []
    public var singles: [Single] = []
}

extension LibraryCatalog {
    /// 一次读完(一个读事务):专辑表扫一遍挑出首页认的专辑,歌曲表按范围扫一遍,只读 id、专辑 id、两个加入时间与
    /// extra(覆盖值、服务端专辑加入时间),不整首解码。内存:首页认的专辑 id 与每张的最新时间(专辑数那么多,查询
    /// 结束就放),三份各自至多几十、上百项的前几名。时间是 `timeIntervalSinceReferenceDate`,与 `Date` 的比较相同。
    public func carPlayRecentlyAdded(
        scope: LibrarySongScope, songLimit: Int, albumLimit: Int, singleLimit: Int
    ) throws -> LibraryCarPlayRecentlyAdded {
        try reader.read { db in
            let splitsLibrary = try Self.visibleSplitsLibrary(in: db)
            let filter = splitsLibrary
                ? """
                  WHERE a.key IN (SELECT albumKey FROM albumSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            var listedKeys: [String: Int32] = [:]
            let albumRows = try Row.fetchCursor(db, sql: "SELECT a.key, a.id, a.title FROM album a \(filter)")
            while let row = try albumRows.next() {
                let id: String = row[1]
                let title: String = row[2]
                guard !id.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                listedKeys[id] = try Self.rowid32(row[0])
            }

            var newest = CarPlayRecentTopList(limit: songLimit)
            var singles = CarPlayRecentTopList(limit: singleLimit)
            var latest: [String: Double] = [:]
            let (songWhere, arguments) = try scope.whereClause(in: db)
            let songRows = try Row.fetchCursor(
                db,
                sql: "SELECT s.id, s.albumID, s.dateAdded, s.serverDateAdded, s.extra FROM song s WHERE \(songWhere)",
                arguments: arguments
            )
            while let row = try songRows.next() {
                let id: String = row[0]
                let fields = try LibraryCatalogSongCodec.recentlyAddedFields(
                    albumID: row[1], dateAdded: row[2], serverDateAdded: row[3], extra: row.dataNoCopy(atIndex: 4)
                )
                newest.offer(id: id, date: fields.dateAdded)
                let date = fields.serverAlbumDateAdded ?? fields.serverDateAdded ?? fields.dateAdded
                if let albumID = fields.albumID, listedKeys[albumID] != nil {
                    latest[albumID] = max(latest[albumID] ?? -Double.infinity, date)
                } else {
                    singles.offer(id: id, date: date)
                }
            }

            var albums = CarPlayRecentTopList(limit: albumLimit)
            for (id, date) in latest { albums.offer(id: id, date: date) }
            return LibraryCarPlayRecentlyAdded(
                songIDs: newest.entries.map(\.id),
                albums: albums.entries.compactMap { entry in
                    listedKeys[entry.id].map { LibraryCarPlayRecentlyAdded.Album(key: $0, id: entry.id, date: entry.date) }
                },
                singles: singles.entries.map { LibraryCarPlayRecentlyAdded.Single(id: $0.id, date: $0.date) }
            )
        }
    }
}

/// 按(时间从新到旧、同时间按 id)的前 `limit` 项。id 在一份里不重复,所以是全序,与整份排好再截相同。
/// 新来的一项只在挤得进前几名时才插进去(二分找位置),大曲库里绝大多数行一次比较就过去了。
struct CarPlayRecentTopList {
    let limit: Int
    private(set) var entries: [(id: String, date: Double)] = []

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    static func precedes(_ lhs: (id: String, date: Double), _ rhs: (id: String, date: Double)) -> Bool {
        lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
    }

    mutating func offer(id: String, date: Double) {
        guard limit > 0 else { return }
        let entry = (id: id, date: date)
        if entries.count == limit, let last = entries.last, !Self.precedes(entry, last) { return }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if Self.precedes(entries[middle], entry) { lower = middle + 1 } else { upper = middle }
        }
        entries.insert(entry, at: lower)
        if entries.count > limit { entries.removeLast() }
    }
}
