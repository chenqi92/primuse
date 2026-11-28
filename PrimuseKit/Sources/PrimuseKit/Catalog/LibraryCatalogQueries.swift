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
        try reader.read { db in
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
        try reader.read { db in
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

    /// 行缓存按 id 取一首用:这一行连同它的行号;目录里没有时为 nil。走按 id 读专用的连接
    /// (不排在连接池后面),语句只编译一次。
    func songWithRowid(id: String) throws -> (rowid: Int32, song: Song)? {
        try pointRead { db in
            let statement = try db.cachedStatement(sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom) WHERE song.id = ?
                """)
            guard let row = try Row.fetchOne(statement, arguments: [id]) else { return nil }
            let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
            return (try Self.rowid32(rowid), try LibraryCatalogSongCodec.decode(row))
        }
    }

    /// 行缓存按 id 取一批用:id → (行号, 歌),不存在的不在结果里。调用方已经过了上限检查。
    /// 与单首的同一个连接。
    func songsWithRowids(ids: [String]) throws -> [String: (rowid: Int32, song: Song)] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: (rowid: Int32, song: Song)] = [:]
        result.reserveCapacity(ids.count)
        try pointRead { db in
            for chunk in Self.chunks(of: Array(Set(ids))) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom)
                        WHERE song.id IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk)
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    let song = try LibraryCatalogSongCodec.decode(row)
                    result[song.id] = (try Self.rowid32(rowid), song)
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
        try reader.read { db in
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

    /// id → 它所在的音乐源;不在目录里的 id 不在结果里。只读两列,不物化行。
    public func sourceIDs(forIDs ids: [String]) throws -> [String: String] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: ids.count)
        let requested = Array(Set(ids.prefix(admitted)))
        var result: [String: String] = [:]
        try reader.read { db in
            for chunk in Self.chunks(of: requested) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT s.id, source.id FROM song s JOIN source ON source.key = s.sourceKey
                        WHERE s.id IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk)
                )
                while let row = try rows.next() {
                    let id: String = row[0]
                    let source: String = row[1]
                    result[id] = source
                }
            }
        }
        return result
    }

    public func song(id: String) throws -> Song? {
        try songs(ids: [id]).first
    }

    // MARK: - Counts

    public func songCount(_ scope: LibrarySongScope = .visible) throws -> Int {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM song s WHERE \(sql)", arguments: arguments) ?? 0
        }
    }

    /// 范围里的歌曲 id,只读一列、不解码整首歌。给按类别要整份 id 集合的用(不装歌曲模型的启动时补上
    /// 有声与环境音的 id 表);结果与范围同阶,调用方只拿它要小的那几类。
    public func songIDSet(_ scope: LibrarySongScope) throws -> Set<String> {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            var ids = Set<String>()
            let cursor = try String.fetchCursor(db, sql: "SELECT s.id FROM song s WHERE \(sql)", arguments: arguments)
            while let id = try cursor.next() { ids.insert(id) }
            return ids
        }
    }

    public func containsSongs(_ scope: LibrarySongScope) throws -> Bool {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM song s WHERE \(sql))", arguments: arguments) ?? false
        }
    }

    /// 按音乐源计数。结果大小与音乐源个数同阶。
    public func songCountsBySource(_ scope: LibrarySongScope = .everything) throws -> [String: Int] {
        try reader.read { db in
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
        try reader.read { db in try Self.fetchAggregates(scope, in: db) }
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

    /// 源内某目录下的歌:`recursive` 为 false 时只要直接子项,为 true 时连同各级子文件夹(沿文件夹树)。
    public func rowList(sourceID: String, directory: String, recursive: Bool) throws -> LibraryRowList {
        let directory = Self.normalizedDirectory(directory)
        if recursive {
            if directory.isEmpty {
                return try rowList(.source(sourceID))
            }
            return try rowList { db in
                guard let folder = try Self.folderKey(sourceID: sourceID, path: directory, in: db) else { return ("0", []) }
                return ("""
                    s.folderKey IN (
                        WITH RECURSIVE subtree(key) AS (
                            SELECT ? UNION ALL
                            SELECT f.key FROM folder f JOIN subtree ON f.parentKey = subtree.key
                            WHERE f.sourceKey = (SELECT sourceKey FROM folder WHERE key = ?))
                        SELECT key FROM subtree)
                    """, [folder, folder])
            }
        }
        return try rowList { db in
            ("s.folderKey = ?", [try Self.folderKey(sourceID: sourceID, path: directory, in: db) ?? -1])
        }
    }

    /// 同一个文件的所有行(CUE 分轨共用一个文件)。
    public func rowList(sourceID: String, filePath: String) throws -> LibraryRowList {
        try rowList { db in
            ("\(try Self.sourceKeyTerm(sourceID, in: db)) AND s.pathHash = ? AND s.filePath = ?",
             [LibraryCatalogDerivedFields.pathHash(filePath), LibraryCatalogDerivedFields.columnText(filePath)])
        }
    }

    /// 同一目录里共用某个旁挂文件(歌词、封面)的行。
    public func rowList(
        sourceID: String,
        directory: String,
        sharing column: LibraryCatalogSidecarColumn,
        fileName: String
    ) throws -> LibraryRowList {
        try rowList { db in
            ("s.folderKey = ? AND s.\(column.rawValue) = ?",
             [try Self.folderKey(sourceID: sourceID, path: Self.normalizedDirectory(directory), in: db) ?? -1,
              LibraryCatalogDerivedFields.columnText(fileName)])
        }
    }

    /// 某目录下文件名主干(去掉扩展名)的集合,最多 `limit` 个。
    public func fileStems(sourceID: String, directory: String, limit: Int = LibraryScale.maxMaterializedRows) throws -> Set<String> {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        return try reader.read { db in
            var stems: Set<String> = []
            let paths = try String.fetchCursor(
                db,
                sql: """
                    SELECT DISTINCT s.filePath FROM song s WHERE s.folderKey = ? LIMIT ?
                    """,
                arguments: [try Self.folderKey(sourceID: sourceID, path: Self.normalizedDirectory(directory), in: db) ?? -1, cap + 1]
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
        try reader.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT s.id FROM song s
                    WHERE s.pathHash = ? AND \(try Self.sourceKeyTerm(sourceID, in: db)) AND s.filePath = ?
                    ORDER BY s.rowid LIMIT 1
                    """,
                arguments: [LibraryCatalogDerivedFields.pathHash(filePath), LibraryCatalogDerivedFields.columnText(filePath)]
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
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT s.rowid, s.id, s.filePath FROM song s WHERE \(sql) ORDER BY s.rowid",
                arguments: arguments
            )
            while let row = try rows.next() {
                guard try body(try Self.rowid32(row[0]), row[1], row[2]) else { return }
            }
        }
    }

    /// 流式遍历一个范围的 (行号, 标题),按库内顺序;`body` 返回 false 时提前结束。只读这两列,不物化整首歌:
    /// 按标题粗筛候选(找「同一首歌的另一份」)时用,命中的行号再交给 `songs(rowids:)`。
    public func forEachSongTitle(
        _ scope: LibrarySongScope,
        _ body: (_ rowid: Int32, _ title: String) throws -> Bool
    ) throws {
        try reader.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT s.rowid, s.title FROM song s WHERE \(sql) ORDER BY s.rowid",
                arguments: arguments
            )
            while let row = try rows.next() {
                guard try body(try Self.rowid32(row[0]), row[1]) else { return }
            }
        }
    }

    /// 流式遍历一个范围的整首歌,按库内顺序,每批 `LibraryScale.importBatchSize` 首。
    public func forEachSong(
        _ scope: LibrarySongScope,
        _ body: (_ rowid: Int32, _ song: Song) throws -> Bool
    ) throws {
        var lastRowid: Int64 = 0
        while true {
            var batch: [(Int32, Song)] = []
            try reader.read { db in
                let (sql, arguments) = try scope.whereClause(in: db)
                var batchArguments = arguments
                batchArguments += [lastRowid, LibraryScale.importBatchSize]
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns.replacingOccurrences(of: "song.", with: "s."))
                        FROM song s JOIN source ON source.key = s.sourceKey
                        WHERE \(sql) AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                        """,
                    arguments: batchArguments
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    batch.append((try Self.rowid32(rowid), try LibraryCatalogSongCodec.decode(row)))
                }
            }
            guard let last = batch.last else { return }
            for (rowid, song) in batch {
                guard try body(rowid, song) else { return }
            }
            lastRowid = Int64(last.0)
            if batch.count < LibraryScale.importBatchSize { return }
        }
    }

    // MARK: - Helpers

    /// 库内顺序就是行号顺序(导入按 (orderKey, id) 写入、新行追加到尾)。
    func rowList(
        orderBy: String = "s.rowid",
        aggregatesScope: LibrarySongScope? = nil,
        limit: Int? = nil,
        where makeWhere: (Database) throws -> (String, StatementArguments)
    ) throws -> LibraryRowList {
        try reader.read { db in
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

    /// 去掉目录参数末尾的斜杠("Music/X/" 与 "Music/X" 是同一个目录;根 "/" 不动)。
    static func normalizedDirectory(_ directory: String) -> String {
        var value = directory
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 源内某个目录(与 `AlbumArtistInferencePolicy.directory(ofPath:)` 同一口径)的文件夹键。
    static func folderKey(sourceID: String, path: String, in db: Database) throws -> Int64? {
        guard let sourceKey = try Int64.fetchOne(db, sql: "SELECT key FROM source WHERE id = ?", arguments: [sourceID]) else {
            return nil
        }
        var parent: Int64 = 0
        for component in GroupingMaintenance.folderChain(of: path) {
            guard let key = try Int64.fetchOne(db, sql: """
                SELECT key FROM folder WHERE sourceKey = ? AND parentKey = ? AND name = ? AND oddPath = ?
                """, arguments: [sourceKey, parent, component.name, component.oddPath]) else { return nil }
            parent = key
        }
        return parent == 0 ? nil : parent
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
