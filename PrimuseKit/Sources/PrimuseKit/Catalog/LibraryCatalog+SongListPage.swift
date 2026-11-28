import Foundation
import GRDB

// 歌曲页在目录上的两种列表形式:按本机播放次数排序、页内查找。两者都要与内存路径
// (`SongListSnapshotBuilder` 的比较器、`LibraryFindPolicy`)逐行一致。

extension LibraryCatalog {
    // MARK: - 播放次数排序

    /// 「播放次数」排序:范围内的行按 (次数, id) 排,与 `SongListSnapshotBuilder` 的比较器逐行一致。
    ///
    /// 次数来自本机播放记录(不在目录里),由调用方给;没有的按 0。次数不同按次数(方向随排序),
    /// 次数相同(包括都没播过)按 id 升序,降序时也是 id 升序。所以列表是「范围内按 id 排好的行,
    /// 把有次数的那些按 (次数, id) 挪到前面(降序)或后面(升序)」:有次数的只有播放记录那么多,
    /// 按 id 逐个点查;其余的走 id 索引。不分节。
    public func songRowList(
        playCounts: [String: Int],
        ascending: Bool,
        scope: LibrarySongScope = .visibleMusic
    ) throws -> LibraryRowList {
        try reader.read { db in
            let revision = try Self.revision(in: db)
            let (whereSQL, arguments) = try scope.whereClause(in: db)

            var counted: [(rowid: Int32, id: String, count: Int)] = []
            counted.reserveCapacity(playCounts.count)
            let lookup = try db.cachedStatement(sql: "SELECT s.rowid FROM song AS s WHERE s.id = ? AND (\(whereSQL))")
            for (id, count) in playCounts where count != 0 {
                let rowArguments: StatementArguments = [id]
                guard let rowid = try Int64.fetchOne(lookup, arguments: rowArguments + arguments) else { continue }
                counted.append((try Self.rowid32(rowid), id, count))
            }
            counted.sort { lhs, rhs in
                if lhs.count != rhs.count { return ascending ? lhs.count < rhs.count : lhs.count > rhs.count }
                return lhs.id < rhs.id
            }
            let countedRowids = Set(counted.map(\.rowid))
            let uncounted = try Self.rowidsInIDOrder(whereSQL: whereSQL, arguments: arguments, skipping: countedRowids, in: db)

            // 次数为 0 的一组夹在负数与正数之间(播放记录折出来的只有正数,这里照比较器的口径写全)。
            var rowids = ContiguousArray<Int32>()
            rowids.reserveCapacity(counted.count + uncounted.count)
            let before = counted.filter { ascending ? $0.count < 0 : $0.count > 0 }
            let after = counted.filter { ascending ? $0.count > 0 : $0.count < 0 }
            rowids.append(contentsOf: before.map(\.rowid))
            rowids.append(contentsOf: uncounted)
            rowids.append(contentsOf: after.map(\.rowid))
            return LibraryRowList(rowids: rowids, revision: revision)
        }
    }

    /// 范围内的行号按 id 的 Swift 字符串先后(比较器的 id 兜底)。全是 ASCII 时字节序就是 Swift 的先后,
    /// 直接走 id 索引;碰到非 ASCII 的 id(字节序与 Swift 的比较可能不同,如非 NFC 的写法)整个改用
    /// GRDB 的 `unicodeCompare`(就是 Swift 的 `<`)排一遍。
    private static func rowidsInIDOrder(
        whereSQL: String,
        arguments: StatementArguments,
        skipping skipped: Set<Int32>,
        in db: Database
    ) throws -> ContiguousArray<Int32> {
        var rowids = ContiguousArray<Int32>()
        let byteOrder = try Row.fetchCursor(
            db,
            sql: "SELECT s.rowid, s.id FROM song AS s WHERE \(whereSQL) ORDER BY s.id",
            arguments: arguments
        )
        var asciiOnly = true
        while let row = try byteOrder.next() {
            if let bytes = row.dataNoCopy(atIndex: 1), bytes.contains(where: { $0 >= 0x80 }) {
                asciiOnly = false
                break
            }
            let rowid = try rowid32(row[0])
            if !skipped.contains(rowid) { rowids.append(rowid) }
        }
        guard !asciiOnly else { return rowids }
        rowids.removeAll(keepingCapacity: true)
        let swiftOrder = try Row.fetchCursor(
            db,
            sql: """
                SELECT s.rowid FROM song AS s WHERE \(whereSQL)
                ORDER BY s.id COLLATE \(DatabaseCollation.unicodeCompare.name)
                """,
            arguments: arguments
        )
        while let row = try swiftOrder.next() {
            let rowid = try rowid32(row[0])
            if !skipped.contains(rowid) { rowids.append(rowid) }
        }
        return rowids
    }

    // MARK: - 页内查找

    /// 页内查找:在 `list` 的顺序上只留匹配 `query` 的行,并给出留下的行的汇总(页头的可播放数、时长)。
    ///
    /// 匹配与 `LibraryFindPolicy.matches(_:song:)` 同一套:歌名、艺人、专辑艺人、专辑与源里的各位艺人,
    /// 每个词落在任一处即可,不分大小写、全半角和变音符号。按行号顺序扫一遍歌曲表,只解码 `list`
    /// 里的行的这几列;结果不分节(内存路径的查找结果也不带字母索引)。
    public func songRowList(_ list: LibraryRowList, matching query: LibraryFindPolicy.Query) throws -> LibraryRowList {
        guard !list.isEmpty else {
            return LibraryRowList(rowids: [], revision: list.revision, aggregates: .init(count: 0, playableCount: 0, totalDuration: 0))
        }
        return try reader.read { db in
            let revision = try Self.revision(in: db)
            let maximum = Int(list.rowids.max() ?? 0)
            var wanted = RowidBits(maximum: maximum)
            for rowid in list.rowids { wanted.insert(rowid) }
            var matched = RowidBits(maximum: maximum)
            var playableCount = 0
            var totalDuration: Double = 0
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.rowid, s.title, s.artistName, s.albumArtistName, s.albumTitle, s.extra,
                        (s.flags & \(LibraryCatalogSongFlags.playable)) != 0, s.durationKey
                    FROM song AS s WHERE s.rowid <= ? ORDER BY s.rowid
                    """,
                arguments: [maximum]
            )
            while let row = try cursor.next() {
                let rowid = try Self.rowid32(row[0])
                guard wanted.contains(rowid) else { continue }
                guard LibraryFindPolicy.matches(query, fields: try LibraryCatalogSongCodec.findFields(row)) else { continue }
                matched.insert(rowid)
                if row[6] as Bool { playableCount += 1 }
                totalDuration += row[7] as Double
            }
            var rowids = ContiguousArray<Int32>()
            for rowid in list.rowids where matched.contains(rowid) { rowids.append(rowid) }
            return LibraryRowList(
                rowids: rowids,
                revision: revision,
                aggregates: .init(count: rowids.count, playableCount: playableCount, totalDuration: totalDuration)
            )
        }
    }
}

extension LibraryCatalogSongCodec {
    /// 页内查找的字段(与 `LibraryFindPolicy.matches(_:song:)` 同序):列 1–4 是歌名、艺人、专辑艺人、
    /// 专辑,列 5 是 `extra`(含 NUL 的原值与源里的各位艺人在这里)。
    static func findFields(_ row: Row) throws -> [String?] {
        var strings: [Int: String] = [:]
        var rare = RareFields()
        if let blob = row.dataNoCopy(atIndex: 5) {
            var reader = ExtraReader(blob)
            var doubles: [Int: UInt64] = [:]
            try decodeRareFields(&reader, into: &rare, strings: &strings, doubles: &doubles)
        }
        var fields: [String?] = [
            strings[Column.title] ?? row[1],
            strings[Column.artistName] ?? row[2],
            strings[Column.albumArtistName] ?? row[3],
            strings[Column.albumTitle] ?? row[4],
        ]
        if let names = rare.sourceArtistNames { fields.append(contentsOf: names.map(Optional.some)) }
        return fields
    }
}

/// 行号集合的位图(行号从 1 起、大致连续,比 `Set<Int32>` 省得多)。
private struct RowidBits {
    private var words: [UInt64]

    init(maximum: Int) {
        words = Array(repeating: 0, count: max(0, maximum) / 64 + 1)
    }

    mutating func insert(_ rowid: Int32) {
        guard rowid >= 0 else { return }
        let value = Int(rowid)
        words[value >> 6] |= 1 << UInt64(value & 63)
    }

    func contains(_ rowid: Int32) -> Bool {
        guard rowid >= 0 else { return false }
        let value = Int(rowid)
        let index = value >> 6
        return index < words.count && words[index] & (1 << UInt64(value & 63)) != 0
    }
}
