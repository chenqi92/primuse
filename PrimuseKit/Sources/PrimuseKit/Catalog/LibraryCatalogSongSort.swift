import Foundation
import GRDB

/// 歌曲列表 15 种排序 × 升降的 SQL。先后与 `SongListSnapshotBuilder.isOrderedBefore`
/// 逐项一致:本地化比较走 GRDB 内置的 `localizedCompare` / `localizedStandardCompare`
/// 排序规则,缺值的位置与方向无关,最后都按 id 升序兜底。
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

    static func plan(
        for order: LibrarySongSortOrder,
        idTerm: String,
        sourceRank: String
    ) -> Plan {
        let localized = LibraryCatalogSchema.localizedCollation
        let standard = LibraryCatalogSchema.localizedStandardCollation
        let direction = order.isAscending ? "ASC" : "DESC"
        func optionalValue(_ column: String) -> String {
            "s.\(column) IS NULL, s.\(column) \(direction), \(idTerm)"
        }
        switch order.criterion {
        case .title:
            return Plan(
                orderBy: "s.titleKey \(direction), s.title COLLATE \(localized) \(direction), \(idTerm)",
                section: .bucket(shift: 0)
            )
        case .fileName:
            return Plan(orderBy: "s.fileNameKey COLLATE \(standard) \(direction), \(idTerm)", section: .none)
        case .artist:
            return Plan(
                orderBy: "s.artistSortKey COLLATE \(localized) \(direction), \(idTerm)",
                section: .bucket(shift: 5)
            )
        case .album:
            return Plan(
                orderBy: """
                    s.albumSortKey COLLATE \(localized) \(direction),
                    s.albumIDSortKey COLLATE \(DatabaseCollation.unicodeCompare.name) \(direction),
                    s.discKey, s.trackKey, s.title COLLATE \(standard), \(idTerm)
                    """,
                section: .bucket(shift: 10)
            )
        case .dateAdded:
            return Plan(orderBy: "s.dateAdded \(direction), \(idTerm)", section: .none)
        case .sourceDate:
            return Plan(orderBy: optionalValue("lastModified"), section: .none)
        case .format:
            return Plan(orderBy: "\(formatRankExpression) \(direction), \(idTerm)", section: .format)
        case .duration:
            return Plan(orderBy: "s.durationKey \(direction), \(idTerm)", section: .none)
        case .playCount:
            return Plan(
                joins: "LEFT JOIN songStat st ON st.songRowid = s.rowid",
                orderBy: "coalesce(st.localPlayCount, 0) \(direction), \(idTerm)",
                section: .none
            )
        case .serverPlayCount:
            return Plan(orderBy: optionalValue("serverPlayCount"), section: .none)
        case .source:
            return Plan(orderBy: "\(sourceRank) \(direction), \(idTerm)", section: .source)
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
                orderBy: "(o.songRowid IS NOT NULL) \(direction), \(idTerm)",
                section: .none
            )
        }
    }

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

extension LibraryCatalog {
    /// 歌曲列表:范围内按 `order` 排好的行号、分节索引与(可选的)汇总。
    /// 在调用线程上同步执行 SQL,调用方放在主线程外。
    ///
    /// 艺人、专辑的降序先按升序走索引,再把相等的一组整体倒过来、组内保持升序
    /// (比较器在这两种排序里组内永远是升序)。组界只在相邻两行字节不同时才调一次
    /// 本地化比较;交给 SQLite 做降序时,它要对每一行调一次排序规则。
    public func songRowList(
        order: LibrarySongSortOrder,
        scope: LibrarySongScope = .visibleMusic,
        includeAggregates: Bool = false
    ) throws -> LibraryRowList {
        try pool.read { db in
            let revision = try Self.revision(in: db)
            let sources = try Row.fetchAll(db, sql: "SELECT key, id, name FROM source").map { row in
                (key: row[0] as Int64, label: (row[2] as String?) ?? (row[1] as String))
            }
            let usesSwiftIDOrder = try Self.metaValue(MetaKey.nonNFCIdentifiers, in: db) == "1"
            let idTerm = usesSwiftIDOrder ? "s.id COLLATE \(DatabaseCollation.unicodeCompare.name)" : "s.id"
            let groupColumns: String?
            switch order {
            case .artistDescending: groupColumns = "CAST(s.artistSortKey AS BLOB), x''"
            case .albumDescending: groupColumns = "CAST(s.albumSortKey AS BLOB), CAST(s.albumIDSortKey AS BLOB)"
            default: groupColumns = nil
            }
            let scanOrder = groupColumns == nil ? order : order.reversed
            let plan = LibraryCatalogSongSort.plan(
                for: scanOrder,
                idTerm: idTerm,
                sourceRank: Self.sourceRankExpression(sources.map { ($0.key, $0.label) })
            )
            let sectionColumn: String
            switch plan.section {
            case .none: sectionColumn = "NULL"
            case .bucket(let shift): sectionColumn = "(s.sectionBucket >> \(shift)) & 31"
            case .format: sectionColumn = "s.fileFormat"
            case .source: sectionColumn = "s.sourceKey"
            }
            let (whereSQL, arguments) = try scope.whereClause(in: db)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.rowid, \(sectionColumn)\(groupColumns.map { ", " + $0 } ?? "") FROM song AS s \(plan.joins)
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
            var rowids = ContiguousArray<Int32>()
            var sectionOffsets: [String: Int] = [:]
            if groupColumns == nil {
                var offset = 0
                while let row = try cursor.next() {
                    rowids.append(try Self.rowid32(row[0]))
                    if let label = label(row), sectionOffsets[label] == nil { sectionOffsets[label] = offset }
                    offset += 1
                }
            } else {
                var ascending = ContiguousArray<Int32>()
                var buckets = ContiguousArray<UInt8>()
                var groupStarts = ContiguousArray<Int32>()
                // 名字与专辑 id 按字节读(不分配);字节相同就是同一组,只有字节不同的相邻两行
                // 才解码成字符串,按比较器的口径(本地化比较 / Swift 的规范等价)再判一次。
                var previousName = Data()
                var previousSecond = Data()
                var hasPrevious = false
                while let row = try cursor.next() {
                    let name = row.dataNoCopy(atIndex: 2) ?? Data()
                    let second = row.dataNoCopy(atIndex: 3) ?? Data()
                    if hasPrevious {
                        var same = second == previousSecond
                            || String(decoding: second, as: UTF8.self) == String(decoding: previousSecond, as: UTF8.self)
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
                    if second != previousSecond { previousSecond = Data(second) }
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
