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
            // 组内顺序不随方向变;降序在 `songRowList` 里按组倒序。
            return Plan(
                orderBy: """
                    s.albumSortKey COLLATE \(localized), s.albumIDSortKey COLLATE \(DatabaseCollation.unicodeCompare.name),
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
    static let indexedCriteria: Set<LibrarySongSortCriterion> = [.title, .artist, .album, .dateAdded]

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

    /// 文件名排序:`localizedStandardCompare` 交给 SQLite 排要对每次比较调一次排序规则
    /// (50 万首约 1000 万次,单线程 6 秒)。这里取出名字后分片多核排序再两两归并,比较器相同。
    static func sortByFileName(names: [NSString], rowids: [Int32]) -> [Int32] {
        let count = rowids.count
        guard count > 1 else { return rowids }
        let box = NameBox(names)
        let precedes: @Sendable (Int, Int) -> Bool = { lhs, rhs in
            switch box.names[lhs].localizedStandardCompare(box.names[rhs] as String) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return rowids[lhs] < rowids[rhs]
            }
        }
        let slices = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, count / 4_096))
        let sliceSize = (count + slices - 1) / slices
        let sorted = SortedSlices(count: slices)
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            let start = slice * sliceSize
            let end = min(count, start + sliceSize)
            guard start < end else { return }
            sorted.set(slice, Array(start..<end).sorted(by: precedes))
        }
        var runs = sorted.all.filter { !$0.isEmpty }
        while runs.count > 1 {
            let current = runs
            let pairs = (current.count + 1) / 2
            let merged = SortedSlices(count: pairs)
            DispatchQueue.concurrentPerform(iterations: pairs) { pair in
                let left = current[pair * 2]
                guard pair * 2 + 1 < current.count else { return merged.set(pair, left) }
                let right = current[pair * 2 + 1]
                var output: [Int] = []
                output.reserveCapacity(left.count + right.count)
                var i = 0
                var j = 0
                while i < left.count, j < right.count {
                    if precedes(right[j], left[i]) {
                        output.append(right[j])
                        j += 1
                    } else {
                        output.append(left[i])
                        i += 1
                    }
                }
                output.append(contentsOf: left[i...])
                output.append(contentsOf: right[j...])
                merged.set(pair, output)
            }
            runs = merged.all
        }
        return runs.first?.map { rowids[$0] } ?? []
    }

    /// 不可变的名字数组,只读地跨线程共享。
    private final class NameBox: @unchecked Sendable {
        let names: [NSString]
        init(_ names: [NSString]) { self.names = names }
    }

    /// 每个槽只由一个片写一次,`concurrentPerform` 返回后才读。
    private final class SortedSlices: @unchecked Sendable {
        private let slots: UnsafeMutableBufferPointer<[Int]>
        init(count: Int) {
            slots = .allocate(capacity: count)
            slots.initialize(repeating: [])
        }
        deinit {
            slots.deinitialize()
            slots.deallocate()
        }
        func set(_ index: Int, _ value: [Int]) { slots[index] = value }
        var all: [[Int]] { Array(slots) }
    }
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
        guard !LibraryCatalogSongSort.indexedCriteria.contains(order.criterion) else {
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
        try pool.read { db in
            let revision = try Self.revision(in: db)
            let sources = try Row.fetchAll(db, sql: "SELECT key, id, name FROM source").map { row in
                (key: row[0] as Int64, label: (row[2] as String?) ?? (row[1] as String))
            }
            let (whereSQL, arguments) = try scope.whereClause(in: db)
            var rowids = ContiguousArray<Int32>()
            var sectionOffsets: [String: Int] = [:]

            if order.criterion == .fileName {
                var names: [NSString] = []
                var ids: [Int32] = []
                let cursor = try Row.fetchCursor(
                    db, sql: "SELECT s.rowid, s.fileNameKey FROM song AS s WHERE \(whereSQL)", arguments: arguments
                )
                while let row = try cursor.next() {
                    ids.append(try Self.rowid32(row[0]))
                    names.append((row[1] as String) as NSString)
                }
                let ascending = LibraryCatalogSongSort.sortByFileName(names: names, rowids: ids)
                rowids = ContiguousArray(order.isAscending ? ascending : ascending.reversed())
            } else {
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
                let groupColumns = reversesAlbumGroups
                    ? ", CAST(s.albumSortKey AS BLOB), CAST(s.albumIDSortKey AS BLOB)" : ""
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
