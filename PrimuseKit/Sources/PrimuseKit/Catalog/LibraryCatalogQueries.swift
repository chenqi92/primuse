import Foundation
import GRDB

/// 查询范围:内容类别、单个音乐源、是否含停用源、只要可播放、只要已下载。
public struct LibrarySongScope: Sendable, Hashable {
    /// nil 表示所有类别。
    public var kinds: Set<LibraryCatalogContentKind>?
    public var sourceID: String?
    public var includesDisabledSources: Bool
    public var playableOnly: Bool
    public var downloadedOnly: Bool

    public init(
        kinds: Set<LibraryCatalogContentKind>? = nil,
        sourceID: String? = nil,
        includesDisabledSources: Bool = false,
        playableOnly: Bool = false,
        downloadedOnly: Bool = false
    ) {
        self.kinds = kinds
        self.sourceID = sourceID
        self.includesDisabledSources = includesDisabledSources
        self.playableOnly = playableOnly
        self.downloadedOnly = downloadedOnly
    }

    /// 整库,含停用源(历史记录按 id 找歌用)。
    public static let everything = LibrarySongScope(includesDisabledSources: true)
    /// 已启用源里的全部歌曲。
    public static let visible = LibrarySongScope()
    /// 已启用源里的音乐(歌曲列表的默认范围)。
    public static let visibleMusic = LibrarySongScope(kinds: [.music])

    public static func source(_ sourceID: String, includesDisabled: Bool = true) -> LibrarySongScope {
        LibrarySongScope(sourceID: sourceID, includesDisabledSources: includesDisabled)
    }

    /// `WHERE` 子句(歌曲表别名 `s`)与参数。音乐源先解析成整数键写进语句,
    /// 查询规划才看得出是常量、用得上 (sourceKey, …) 索引。
    func whereClause(in db: Database) throws -> (sql: String, arguments: StatementArguments) {
        var terms: [String] = []
        let arguments = StatementArguments()
        if let kinds {
            let values = kinds.map(\.rawValue).sorted()
            if values.count == 1 {
                terms.append("s.kind = \(values[0])")
            } else {
                terms.append("s.kind IN (\(values.map(String.init).joined(separator: ",")))")
            }
        }
        if let sourceID {
            terms.append(try LibraryCatalog.sourceKeyTerm(sourceID, in: db))
        }
        if !includesDisabledSources {
            terms.append("s.sourceKey NOT IN (SELECT key FROM source WHERE enabled = 0)")
        }
        if playableOnly {
            terms.append("(s.flags & \(LibraryCatalogSongFlags.playable)) != 0")
        }
        if downloadedOnly {
            terms.append("s.rowid IN (SELECT songRowid FROM songOffline WHERE state = \(LibraryCatalogOfflineState.downloaded.rawValue))")
        }
        return (terms.isEmpty ? "1" : terms.joined(separator: " AND "), arguments)
    }
}

/// 源内路径查询的「旁挂文件」列。
public enum LibraryCatalogSidecarColumn: String, Sendable {
    case lyricsFileName
    case coverArtFileName
}

extension LibraryCatalog {
    // MARK: - Materialization (bounded)

    /// 按 id 批量取,保持输入顺序;不存在的跳过。一次最多 `LibraryScale.maxMaterializedRows` 个。
    public func songs(
        ids: [String],
        scope: LibrarySongScope = .everything,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> [Song] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: ids.count, file: file, line: line)
        let requested = Array(ids.prefix(admitted))
        guard !requested.isEmpty else { return [] }
        var byID: [String: Song] = [:]
        byID.reserveCapacity(requested.count)
        try pool.read { db in
            let (scopeSQL, scopeArguments) = try scope.whereClause(in: db)
            for chunk in Self.chunks(of: Array(Set(requested))) {
                var arguments = StatementArguments(chunk)
                arguments += scopeArguments
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns) FROM song s
                        JOIN source ON source.key = s.sourceKey
                        WHERE s.id IN (\(Self.placeholders(chunk.count))) AND \(scopeSQL)
                        """.replacingOccurrences(of: "song.", with: "s."),
                    arguments: arguments
                )
                while let row = try rows.next() {
                    let song = try LibraryCatalogSongCodec.decode(row)
                    byID[song.id] = song
                }
            }
        }
        return requested.compactMap { byID[$0] }
    }

    /// 按行号批量取,保持输入顺序;已删除的行跳过。
    public func songs(
        rowids: some Collection<Int32>,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> [Song] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: rowids.count, file: file, line: line)
        let requested = Array(rowids.prefix(admitted))
        let byRowid = try songsByRowid(requested)
        return requested.compactMap { byRowid[$0] }
    }

    /// 行缓存用:调用方已经过了上限检查。
    func songsByRowid(_ rowids: [Int32]) throws -> [Int32: Song] {
        guard !rowids.isEmpty else { return [:] }
        var result: [Int32: Song] = [:]
        result.reserveCapacity(rowids.count)
        try pool.read { db in
            for chunk in Self.chunks(of: Array(Set(rowids))) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom)
                        WHERE song.rowid IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    result[try Self.rowid32(rowid)] = try LibraryCatalogSongCodec.decode(row)
                }
            }
        }
        return result
    }

    /// id → 行号,保持顺序;不存在的是 nil。
    public func rowids(forIDs ids: [String]) throws -> [Int32?] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: ids.count)
        let requested = Array(ids.prefix(admitted))
        var byID: [String: Int32] = [:]
        try pool.read { db in
            for chunk in Self.chunks(of: Array(Set(requested))) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT id, rowid FROM song WHERE id IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk)
                )
                while let row = try rows.next() {
                    byID[row[0]] = try Self.rowid32(row[1])
                }
            }
        }
        return requested.map { byID[$0] }
    }

    public func song(id: String) throws -> Song? {
        try songs(ids: [id]).first
    }

    // MARK: - Counts

    public func songCount(_ scope: LibrarySongScope = .visible) throws -> Int {
        try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM song s WHERE \(sql)", arguments: arguments) ?? 0
        }
    }

    public func containsSongs(_ scope: LibrarySongScope) throws -> Bool {
        try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM song s WHERE \(sql))", arguments: arguments) ?? false
        }
    }

    /// 按音乐源计数。结果大小与音乐源个数同阶。
    public func songCountsBySource(_ scope: LibrarySongScope = .everything) throws -> [String: Int] {
        try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            var result: [String: Int] = [:]
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT source.id, count(*) FROM song s JOIN source ON source.key = s.sourceKey
                    WHERE \(sql) GROUP BY s.sourceKey
                    """,
                arguments: arguments
            )
            while let row = try rows.next() { result[row[0]] = row[1] }
            return result
        }
    }

    public func aggregates(_ scope: LibrarySongScope) throws -> LibraryRowList.Aggregates {
        try pool.read { db in try Self.fetchAggregates(scope, in: db) }
    }

    static func fetchAggregates(_ scope: LibrarySongScope, in db: Database) throws -> LibraryRowList.Aggregates {
        let (sql, arguments) = try scope.whereClause(in: db)
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT count(*), total((s.flags & \(LibraryCatalogSongFlags.playable)) != 0), total(s.durationKey)
                FROM song s WHERE \(sql)
                """,
            arguments: arguments
        ) else { return LibraryRowList.Aggregates(count: 0, playableCount: 0, totalDuration: 0) }
        let count: Int = row[0]
        let playable: Double = row[1]
        let duration: Double = row[2]
        return LibraryRowList.Aggregates(count: count, playableCount: Int(playable), totalDuration: duration)
    }

    // MARK: - Ranges in library order

    /// 范围内的行号,按库内顺序。
    public func rowList(_ scope: LibrarySongScope, includeAggregates: Bool = false) throws -> LibraryRowList {
        try rowList(aggregatesScope: includeAggregates ? scope : nil) { db in try scope.whereClause(in: db) }
    }

    /// 源内某目录下的歌:`recursive` 为 false 时只要直接子项。
    public func rowList(sourceID: String, directory: String, recursive: Bool) throws -> LibraryRowList {
        if recursive {
            let normalized = directory.hasSuffix("/") ? directory : directory + "/"
            if directory.isEmpty {
                return try rowList(.source(sourceID))
            }
            return try rowList(orderBy: "+s.orderKey, s.id") { db in
                ("\(try Self.sourceKeyTerm(sourceID, in: db)) AND s.filePath >= ? AND s.filePath < ?",
                 [normalized, LibraryCatalogPath.upperBound(forPrefix: normalized)])
            }
        }
        return try rowList(orderBy: "+s.orderKey, s.id") { db in
            ("\(try Self.sourceKeyTerm(sourceID, in: db)) AND s.directoryKey = ?", [directory])
        }
    }

    /// 同一个文件的所有行(CUE 分轨共用一个文件)。
    public func rowList(sourceID: String, filePath: String) throws -> LibraryRowList {
        try rowList(orderBy: "+s.orderKey, s.id") { db in
            ("\(try Self.sourceKeyTerm(sourceID, in: db)) AND s.filePath = ?", [filePath])
        }
    }

    /// 同一目录里共用某个旁挂文件(歌词、封面)的行。
    public func rowList(
        sourceID: String,
        directory: String,
        sharing column: LibraryCatalogSidecarColumn,
        fileName: String
    ) throws -> LibraryRowList {
        try rowList(orderBy: "+s.orderKey, s.id") { db in
            ("\(try Self.sourceKeyTerm(sourceID, in: db)) AND s.directoryKey = ? AND s.\(column.rawValue) = ?",
             [directory, fileName])
        }
    }

    /// 某目录下文件名主干(去掉扩展名)的集合,最多 `limit` 个。
    public func fileStems(sourceID: String, directory: String, limit: Int = LibraryScale.maxMaterializedRows) throws -> Set<String> {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        return try pool.read { db in
            var stems: Set<String> = []
            let paths = try String.fetchCursor(
                db,
                sql: """
                    SELECT DISTINCT s.filePath FROM song s
                    WHERE \(try Self.sourceKeyTerm(sourceID, in: db)) AND s.directoryKey = ? LIMIT ?
                    """,
                arguments: [directory, cap + 1]
            )
            while let path = try paths.next() {
                stems.insert(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            if stems.count > cap {
                LibraryScaleGuard.admitMaterialization(count: stems.count, limit: cap)
                stems = Set(stems.prefix(cap))
            }
            return stems
        }
    }

    /// 源内某个精确路径的歌曲 id(没有就是 nil;CUE 分轨取库内顺序第一个)。
    public func songID(sourceID: String, filePath: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT s.id FROM song s WHERE \(try Self.sourceKeyTerm(sourceID, in: db)) AND s.filePath = ?
                    ORDER BY +s.orderKey, s.id LIMIT 1
                    """,
                arguments: [filePath]
            )
        }
    }

    /// 范围内库内顺序的第一首。
    public func firstSong(_ scope: LibrarySongScope) throws -> Song? {
        let list = try rowList(limit: 1) { db in try scope.whereClause(in: db) }
        return try songs(rowids: list.rowids).first
    }

    /// 流式遍历一个范围的 (行号, id, 路径),按库内顺序;`body` 返回 false 时提前结束。
    /// 内存只占一批。
    public func forEachSongIdentity(
        _ scope: LibrarySongScope,
        _ body: (_ rowid: Int32, _ id: String, _ filePath: String) throws -> Bool
    ) throws {
        try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT s.rowid, s.id, s.filePath FROM song s WHERE \(sql) ORDER BY s.orderKey, s.id",
                arguments: arguments
            )
            while let row = try rows.next() {
                guard try body(try Self.rowid32(row[0]), row[1], row[2]) else { return }
            }
        }
    }

    /// 流式遍历一个范围的整首歌,按库内顺序,每批 `LibraryScale.importBatchSize` 首。
    public func forEachSong(
        _ scope: LibrarySongScope,
        _ body: (_ rowid: Int32, _ song: Song) throws -> Bool
    ) throws {
        var lastOrderKey = Int64.min
        var lastID = ""
        while true {
            var batch: [(Int32, Song, Int64)] = []
            try pool.read { db in
                let (sql, arguments) = try scope.whereClause(in: db)
                var batchArguments = arguments
                batchArguments += [lastOrderKey, lastOrderKey, lastID, LibraryScale.importBatchSize]
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns.replacingOccurrences(of: "song.", with: "s.")), s.orderKey
                        FROM song s JOIN source ON source.key = s.sourceKey
                        WHERE \(sql) AND (s.orderKey > ? OR (s.orderKey = ? AND s.id > ?))
                        ORDER BY s.orderKey, s.id LIMIT ?
                        """,
                    arguments: batchArguments
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    batch.append((try Self.rowid32(rowid), try LibraryCatalogSongCodec.decode(row), row[LibraryCatalogSongCodec.Column.extra + 1]))
                }
            }
            guard let last = batch.last else { return }
            for (rowid, song, _) in batch {
                guard try body(rowid, song) else { return }
            }
            lastOrderKey = last.2
            lastID = last.1.id
            if batch.count < LibraryScale.importBatchSize { return }
        }
    }

    // MARK: - Helpers

    func rowList(
        orderBy: String = "s.orderKey, s.id",
        aggregatesScope: LibrarySongScope? = nil,
        limit: Int? = nil,
        where makeWhere: (Database) throws -> (String, StatementArguments)
    ) throws -> LibraryRowList {
        try pool.read { db in
            let revision = try Self.revision(in: db)
            let (whereSQL, arguments) = try makeWhere(db)
            var rowids = ContiguousArray<Int32>()
            let limitSQL = limit.map { " LIMIT \($0)" } ?? ""
            let cursor = try Int64.fetchCursor(
                db,
                sql: "SELECT s.rowid FROM song s WHERE \(whereSQL) ORDER BY \(orderBy)\(limitSQL)",
                arguments: arguments
            )
            while let rowid = try cursor.next() { rowids.append(try Self.rowid32(rowid)) }
            let aggregates = try aggregatesScope.map { try Self.fetchAggregates($0, in: db) }
            return LibraryRowList(rowids: rowids, revision: revision, aggregates: aggregates)
        }
    }

    /// `s.sourceKey = <键>`;目录里没有这个源时是恒假。
    static func sourceKeyTerm(_ sourceID: String, in db: Database) throws -> String {
        guard let key = try Int64.fetchOne(db, sql: "SELECT key FROM source WHERE id = ?", arguments: [sourceID]) else {
            return "0"
        }
        return "s.sourceKey = \(key)"
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    static func chunks<T>(of values: [T], size: Int = 900) -> [ArraySlice<T>] {
        stride(from: 0, to: values.count, by: size).map { values[$0..<min($0 + size, values.count)] }
    }
}

enum LibraryCatalogPath {
    /// 以 `prefix` 开头的字符串的严格上界:把最后一个码位加一(UTF-8 字节序与码位序一致)。
    static func upperBound(forPrefix prefix: String) -> String {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.popLast() {
            var next = last.value + 1
            if next == 0xD800 { next = 0xE000 }
            if next <= 0x10FFFF, let scalar = Unicode.Scalar(next) {
                scalars.append(scalar)
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars)
                return String(view)
            }
        }
        return "\u{10FFFF}\u{10FFFF}"
    }
}
