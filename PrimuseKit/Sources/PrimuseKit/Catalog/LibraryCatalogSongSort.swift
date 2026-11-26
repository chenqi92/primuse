import Foundation
import GRDB

/// 歌曲列表 15 种排序 × 升降的 SQL。键的先后与 `SongListSnapshotBuilder.isOrderedBefore`
/// 一致:本地化比较走 GRDB 内置的 `localizedCompare` / `localizedStandardCompare` 排序规则,
/// 缺值的位置与方向无关。键完全相等的行按行号排,降序时连行号一起倒过来(比较器按 id 兜底;
/// 行号让索引不必带上 id,倒着扫同一条索引就是降序)。专辑排序例外:组内永远按碟号、曲号升序。
enum LibraryCatalogSongSort {
    enum SectionSource {
        case none
        /// `sectionBucket` 里第 `shift` 位起的 5 位是字母下标。
        case bucket(shift: Int)
        case format
        case source
    }

    struct Plan {
        var joins = ""
        var orderBy: String
        var section: SectionSource
    }

    static func plan(for order: LibrarySongSortOrder, sourceRank: String) -> Plan {
        let localized = LibraryCatalogSchema.localizedCollation
        let standard = LibraryCatalogSchema.localizedStandardCollation
        let direction = order.isAscending ? "ASC" : "DESC"
        let rowid = "s.rowid \(direction)"
        func optionalValue(_ column: String) -> String {
            "s.\(column) IS NULL, s.\(column) \(direction), \(rowid)"
        }
        switch order.criterion {
        case .title:
            return Plan(
                orderBy: "s.titleKey \(direction), s.title COLLATE \(localized) \(direction), \(rowid)",
                section: .bucket(shift: 0)
            )
        case .fileName:
            return Plan(orderBy: "s.fileNameKey COLLATE \(standard) \(direction), \(rowid)", section: .none)
        case .artist:
            return Plan(
                orderBy: "coalesce(s.artistName, '') COLLATE \(localized) \(direction), \(rowid)",
                section: .bucket(shift: 5)
            )
        case .album:
            // 组内顺序不随方向变;降序在 `songRowList` 里按组倒序。表达式与索引 `song_sort_album` 一字不差。
            return Plan(
                orderBy: """
                    \(LibraryCatalogSchema.albumSortExpression) COLLATE \(localized),
                    \(LibraryCatalogSchema.albumIDSortExpression) COLLATE \(DatabaseCollation.unicodeCompare.name),
                    s.discKey, s.trackKey, s.title COLLATE \(standard), s.rowid
                    """,
                section: .bucket(shift: 10)
            )
        case .dateAdded:
            return Plan(orderBy: "s.dateAdded \(direction), \(rowid)", section: .none)
        case .sourceDate:
            return Plan(orderBy: optionalValue("lastModified"), section: .none)
        case .format:
            return Plan(orderBy: "\(formatRankExpression) \(direction), \(rowid)", section: .format)
        case .duration:
            return Plan(orderBy: "s.durationKey \(direction), \(rowid)", section: .none)
        case .playCount:
            return Plan(
                joins: "LEFT JOIN songStat st ON st.songRowid = s.rowid",
                orderBy: "coalesce(st.localPlayCount, 0) \(direction), \(rowid)",
                section: .none
            )
        case .serverPlayCount:
            return Plan(orderBy: optionalValue("serverPlayCount"), section: .none)
        case .source:
            return Plan(orderBy: "\(sourceRank) \(direction), \(rowid)", section: .source)
        case .year:
            return Plan(orderBy: optionalValue("year"), section: .none)
        case .bitRate:
            return Plan(orderBy: optionalValue("bitRate"), section: .none)
        case .bitDepth:
            return Plan(orderBy: optionalValue("bitDepth"), section: .none)
        case .downloaded:
            return Plan(
                joins: """
                    LEFT JOIN songOffline o ON o.songRowid = s.rowid AND o.state = \(LibraryCatalogOfflineState.downloaded.rawValue)
                    """,
                orderBy: "(o.songRowid IS NOT NULL) \(direction), \(rowid)",
                section: .none
            )
        }
    }

    /// 有覆盖索引的排序;其余的结果进 `LibraryCatalog` 的结果缓存。
    static let indexedCriteria: Set<LibrarySongSortCriterion> = [.title, .artist, .album, .dateAdded, .fileName]
    /// 索引在迁移后由后台补建的那几种(`LibraryCatalogSchema.backgroundSortIndexNames`)。
    static let backgroundIndexedCriteria: Set<LibrarySongSortCriterion> = [.artist, .album, .fileName]

    /// 格式按 `displayName.compare` 的先后排名,显示名相同的同名次。
    static let formatRanks: [String: Int] = {
        let sorted = AudioFormat.allCases.sorted { $0.displayName.compare($1.displayName) == .orderedAscending }
        var ranks: [String: Int] = [:]
        var rank = 0
        var previous: AudioFormat?
        for format in sorted {
            if let previous, previous.displayName.compare(format.displayName) != .orderedSame { rank += 1 }
            ranks[format.rawValue] = rank
            previous = format
        }
        return ranks
    }()

    static let formatRankExpression: String = {
        let cases = formatRanks.sorted { $0.key < $1.key }
            .map { "WHEN '\($0.key.replacingOccurrences(of: "'", with: "''"))' THEN \($0.value)" }
            .joined(separator: " ")
        return "(CASE s.fileFormat \(cases) ELSE \(formatRanks.count + 1) END)"
    }()

    static let formatLabels: [String: String] = Dictionary(
        uniqueKeysWithValues: AudioFormat.allCases.map {
            ($0.rawValue, LibraryCollationPolicy.indexLetter(for: $0.displayName))
        }
    )
}

/// 没有索引的排序结果按 (排序, 范围, 修订号) 缓存,总行数有上限,超出按最久未用淘汰。
final class LibrarySongListCache: @unchecked Sendable {
    struct Key: Hashable {
        let order: LibrarySongSortOrder
        let scope: LibrarySongScope
        let revision: Int64
        let includesAggregates: Bool
    }

    /// 全局行号预算(PLAN §4.3,400 万行)里给歌曲列表缓存的部分。
    static let maximumRows = 1_500_000
    private let lock = NSLock()
    private var entries: [Key: LibraryRowList] = [:]
    private var recency: [Key] = []

    func value(for key: Key) -> LibraryRowList? {
        lock.withLock {
            guard let value = entries[key] else { return nil }
            recency.removeAll { $0 == key }
            recency.append(key)
            return value
        }
    }

    func store(_ value: LibraryRowList, for key: Key) {
        lock.withLock {
            entries = entries.filter { $0.key.revision == key.revision }
            recency.removeAll { entries[$0] == nil || $0 == key }
            entries[key] = value
            recency.append(key)
            var total = entries.values.reduce(0) { $0 + $1.count }
            while total > Self.maximumRows, recency.count > 1 {
                let evicted = recency.removeFirst()
                total -= entries.removeValue(forKey: evicted)?.count ?? 0
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            recency.removeAll()
        }
    }
}

extension LibraryCatalog {
    /// 歌曲列表:范围内按 `order` 排好的行号、分节索引与(可选的)汇总。
    /// 在调用线程上同步执行 SQL,调用方放在主线程外。没有索引的排序结果缓存到下一次修订。
    public func songRowList(
        order: LibrarySongSortOrder,
        scope: LibrarySongScope = .visibleMusic,
        includeAggregates: Bool = false
    ) throws -> LibraryRowList {
        // 有索引的排序直接扫索引,不缓存;迁移后排序索引还在后台补建时,这几种也要整表排序,先缓存。
        var indexed = LibraryCatalogSongSort.indexedCriteria.contains(order.criterion)
        if indexed, LibraryCatalogSongSort.backgroundIndexedCriteria.contains(order.criterion), try hasPendingSortIndexes() {
            indexed = false
        }
        guard !indexed else {
            return try buildSongRowList(order: order, scope: scope, includeAggregates: includeAggregates)
        }
        let revision = try self.revision()
        let key = LibrarySongListCache.Key(order: order, scope: scope, revision: revision, includesAggregates: includeAggregates)
        if let cached = songListCache.value(for: key) { return cached }
        let list = try buildSongRowList(order: order, scope: scope, includeAggregates: includeAggregates)
        if list.revision == revision { songListCache.store(list, for: key) }
        return list
    }

    private func buildSongRowList(
        order: LibrarySongSortOrder,
        scope: LibrarySongScope,
        includeAggregates: Bool
    ) throws -> LibraryRowList {
        try reader.read { db in
            let revision = try Self.revision(in: db)
            let sources = try Row.fetchAll(db, sql: "SELECT key, id, name FROM source").map { row in
                (key: row[0] as Int64, label: (row[2] as String?) ?? (row[1] as String))
            }
            let (whereSQL, arguments) = try scope.whereClause(in: db)
            var rowids = ContiguousArray<Int32>()
            var sectionOffsets: [String: Int] = [:]

            do {
                let plan = LibraryCatalogSongSort.plan(
                    for: order, sourceRank: Self.sourceRankExpression(sources.map { ($0.key, $0.label) })
                )
                let reversesAlbumGroups = order == .albumDescending
                let sectionColumn: String
                switch plan.section {
                case .none: sectionColumn = "NULL"
                case .bucket(let shift): sectionColumn = "(s.sectionBucket >> \(shift)) & 31"
                case .format: sectionColumn = "s.fileFormat"
                case .source: sectionColumn = "s.sourceKey"
                }
                // 组键连 COLLATE 也要与索引 `song_sort_album` 的列一字不差:SQLite 只有在表达式完全
                // 相同时才直接读索引里存的值,少了 COLLATE 就逐行回表取 albumTitle、albumID
                // (10 万首多 40–50 ms)。COLLATE 不改变取出的值。
                let groupColumns = reversesAlbumGroups
                    ? """
                      , \(LibraryCatalogSchema.albumSortExpression) COLLATE \(LibraryCatalogSchema.localizedCollation), \
                      \(LibraryCatalogSchema.albumIDSortExpression) COLLATE \(DatabaseCollation.unicodeCompare.name)
                      """
                    : ""
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT s.rowid, \(sectionColumn)\(groupColumns) FROM song AS s \(plan.joins)
                        WHERE \(whereSQL) ORDER BY \(plan.orderBy)
                        """,
                    arguments: arguments
                )
                let sourceLabels = Dictionary(
                    sources.map { ($0.key, LibraryCollationPolicy.indexLetter(for: $0.label)) },
                    uniquingKeysWith: { first, _ in first }
                )
                func label(_ row: Row) -> String? {
                    switch plan.section {
                    case .none: return nil
                    case .bucket: return LibraryCollationPolicy.buckets[min(max(0, row[1] as Int), 26)]
                    case .format: return LibraryCatalogSongSort.formatLabels[row[1] as String]
                    case .source: return sourceLabels[row[1] as Int64]
                    }
                }
                if !reversesAlbumGroups {
                    var offset = 0
                    while let row = try cursor.next() {
                        rowids.append(try Self.rowid32(row[0]))
                        if let label = label(row), sectionOffsets[label] == nil { sectionOffsets[label] = offset }
                        offset += 1
                    }
                } else {
                    // 专辑降序:按升序走索引,把(专辑名, 专辑 id)相同的一组整体倒过来,组内保持升序。
                    // 名字与专辑 id 按字节读(不分配);字节不同的相邻两行才按比较器的口径再判一次。
                    var ascending = ContiguousArray<Int32>()
                    var buckets = ContiguousArray<UInt8>()
                    var groupStarts = ContiguousArray<Int32>()
                    var previousName = Data()
                    var previousAlbum = Data()
                    var hasPrevious = false
                    while let row = try cursor.next() {
                        let name = row.dataNoCopy(atIndex: 2) ?? Data()
                        let album = row.dataNoCopy(atIndex: 3) ?? Data()
                        if hasPrevious {
                            var same = album == previousAlbum
                                || String(decoding: album, as: UTF8.self) == String(decoding: previousAlbum, as: UTF8.self)
                            if same, name != previousName {
                                same = String(decoding: previousName, as: UTF8.self)
                                    .localizedCompare(String(decoding: name, as: UTF8.self)) == .orderedSame
                            }
                            if !same { groupStarts.append(Int32(ascending.count)) }
                        } else {
                            groupStarts.append(0)
                            hasPrevious = true
                        }
                        if name != previousName { previousName = Data(name) }
                        if album != previousAlbum { previousAlbum = Data(album) }
                        ascending.append(try Self.rowid32(row[0]))
                        buckets.append(UInt8(truncatingIfNeeded: min(max(0, row[1] as Int), 26)))
                    }
                    rowids.reserveCapacity(ascending.count)
                    var end = ascending.count
                    for start in groupStarts.reversed() {
                        for index in Int(start)..<end {
                            let label = LibraryCollationPolicy.buckets[Int(buckets[index])]
                            if sectionOffsets[label] == nil { sectionOffsets[label] = rowids.count }
                            rowids.append(ascending[index])
                        }
                        end = Int(start)
                    }
                }
            }
            let sections = SongListSnapshotBuilder.sectionIndexEntries(from: sectionOffsets, order: order)
            let aggregates = includeAggregates ? try Self.fetchAggregates(scope, in: db) : nil
            return LibraryRowList(rowids: rowids, sections: sections, revision: revision, aggregates: aggregates)
        }
    }

    /// 来源按显示名(没有就是 id)的本地化先后排名,同名同名次。
    static func sourceRankExpression(_ sources: [(key: Int64, label: String)]) -> String {
        guard !sources.isEmpty else { return "0" }
        let sorted = sources.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        var cases: [String] = []
        var rank = 0
        var previous: String?
        for source in sorted {
            if let previous, previous.localizedCompare(source.label) != .orderedSame { rank += 1 }
            cases.append("WHEN \(source.key) THEN \(rank)")
            previous = source.label
        }
        return "(CASE s.sourceKey \(cases.joined(separator: " ")) ELSE \(rank + 1) END)"
    }
}
