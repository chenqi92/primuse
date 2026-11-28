import Foundation
import GRDB

/// 搜索页专辑、艺人的预处理文本与逐字倒排,存在搜索库(`library-search.sqlite`)里,不常驻内存。
///
/// 规则与原先 App 里的 `LibraryCatalogSearchIndex`(内存版)逐条相同:
/// - 文本备忘(`texts`):同一段文本(按规范等价算同一段)只预处理一次;要拼音而备忘里没有拼音时
///   换成带拼音的那份;条数超过 `max(1024, 2 × (专辑 × 2 + 艺人))` 时只留眼前专辑、艺人用到的。
/// - 专辑行在专辑列表换了(不是同一个数组)或要拼音而上次没备拼音时整批重排,行指向备忘里当时的那份;
///   艺人行在艺人列表换了时重排,指向当时的那份(之后备忘换成带拼音的,艺人行不跟着换)。
/// - 候选:查询里每个字(专辑只看字母数字,艺人看所有非空白)都出现在该行预处理文本的字里;
///   打分、排序与内存版相同。
///
/// 存法:每个「文本 + 是否带拼音」存一份(`collectionSearchTextVersion`)连同它的字(倒排);
/// 专辑、艺人行只存行号与指向哪一份。专辑列表换了只重写行表,没变的文本不再预处理、不再写倒排。
/// 一个实例占一个 `space`,几个实例共用一个库互不干扰。
public final class LibraryCollectionSearchStore: @unchecked Sendable {
    public struct Output: Sendable {
        public let albums: [Album]
        public let artists: [Artist]

        public init(albums: [Album], artists: [Artist]) {
            self.albums = albums
            self.artists = artists
        }
    }

    private let writer: any DatabaseWriter
    private let space: String
    private var albums: [Album] = []
    private var artists: [Artist] = []
    private var albumIncludesPinyin = false
    /// 按行准备(`searchRows`,曲库目录来的专辑、艺人)时,行是按哪一代目录、带不带拼音排的。
    private var rowsGeneration: Int64?
    private var rowsAlbumPinyin = false
    public private(set) var preparationCount = 0
    public private(set) var lastAlbumCandidateCount = 0

    /// `writer` 里要先建好表(`createTables(in:)`)。
    public init(writer: any DatabaseWriter, space: String = UUID().uuidString) {
        self.writer = writer
        self.space = space
    }

    /// 测试、没有搜索库时用:一个只在这个实例里的内存库。
    public static func temporary() throws -> LibraryCollectionSearchStore {
        let queue = try DatabaseQueue()
        try queue.write { db in try createTables(in: db) }
        return LibraryCollectionSearchStore(writer: queue)
    }

    deinit {
        let space = space
        try? writer.write { db in
            for table in ["collectionSearchAlbum", "collectionSearchArtist", "collectionSearchMemo",
                          "collectionSearchPosting", "collectionSearchTextVersion"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE space = ?", arguments: [space])
            }
        }
        // 按行准备时才建的那张表(老的搜索库里可能没有):单独删,没有这张表也不影响上面几张。
        try? writer.write { db in
            if try db.tableExists(Self.rowTextTable) {
                try db.execute(sql: "DELETE FROM \(Self.rowTextTable) WHERE space = ?", arguments: [space])
            }
        }
    }

    public static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS collectionSearchTextVersion (
                id INTEGER PRIMARY KEY,
                space TEXT NOT NULL,
                textKey TEXT NOT NULL,
                pinyin INTEGER NOT NULL,
                raw TEXT NOT NULL,
                original TEXT NOT NULL,
                latin TEXT NOT NULL,
                initials TEXT NOT NULL,
                semantic TEXT NOT NULL,
                UNIQUE (space, textKey, pinyin)
            );
            CREATE TABLE IF NOT EXISTS collectionSearchMemo (
                space TEXT NOT NULL,
                textKey TEXT NOT NULL,
                version INTEGER NOT NULL,
                PRIMARY KEY (space, textKey)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS collectionSearchPosting (
                space TEXT NOT NULL,
                scalar INTEGER NOT NULL,
                version INTEGER NOT NULL,
                PRIMARY KEY (space, scalar, version)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS collectionSearchPosting_version ON collectionSearchPosting(version);
            CREATE TABLE IF NOT EXISTS collectionSearchAlbum (
                space TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                albumID TEXT NOT NULL,
                titleVersion INTEGER NOT NULL,
                artistVersion INTEGER NOT NULL,
                PRIMARY KEY (space, ordinal)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS collectionSearchAlbum_id ON collectionSearchAlbum(space, albumID);
            CREATE TABLE IF NOT EXISTS collectionSearchArtist (
                space TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                version INTEGER NOT NULL,
                PRIMARY KEY (space, ordinal)
            ) WITHOUT ROWID;
            """)
        try createRowTextTable(in: db)
    }

    static let rowTextTable = "collectionSearchRowText"

    /// 按行准备时(`searchRows`)每一行的 id 与原文(kind 0 专辑名,1 艺人名):同分时按原文比先后,与按数组时
    /// 比 `Album.title` / `Artist.name` 一样(备忘里的 `raw` 是规范等价写法里先来的那一种,不能拿来比)。
    /// 老的搜索库里没有这张表:按行准备时现建。
    static func createRowTextTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(rowTextTable) (
                space TEXT NOT NULL,
                kind INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                rowID TEXT NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY (space, kind, ordinal)
            ) WITHOUT ROWID;
            """)
    }

    /// 上一次运行留下的(每次运行的实例都换新的 `space`):打开搜索库时清掉。
    public static func removeAll(in db: Database) throws {
        for table in ["collectionSearchAlbum", "collectionSearchArtist", "collectionSearchMemo",
                      "collectionSearchPosting", "collectionSearchTextVersion"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
        if try db.tableExists(rowTextTable) { try db.execute(sql: "DELETE FROM \(rowTextTable)") }
    }

    // MARK: - Search

    public func search(
        query: String, albums nextAlbums: [Album], artists nextArtists: [Artist],
        relatedAlbums: [Album] = [], semanticArtists: Bool = false,
        includePinyin: Bool = true,
        isCancelled: () -> Bool = { false }
    ) throws -> Output {
        let matcher = LibrarySearchTextMatcher(query: query)
        guard !matcher.rawQuery.isEmpty, !isCancelled(),
              try prepare(albums: nextAlbums, artists: nextArtists,
                          includesPinyin: includePinyin && matcher.requiresPinyinCandidates, isCancelled: isCancelled)
        else { return Output(albums: [], artists: []) }

        let space = space
        let albumScalars = Self.scalars(matcher.normalizedQuery, alphanumericOnly: true)
        let semanticQuery = ListeningSpaceSearchPolicy.normalized(query)
        let artistScalars = Self.scalars(semanticQuery, alphanumericOnly: false)
        typealias Prepared = LibrarySearchTextMatcher.PreparedText
        typealias AlbumRow = (ordinal: Int, title: Prepared, artist: Prepared)
        typealias ArtistRow = (ordinal: Int, text: Prepared)
        let (albumRows, relatedIDs, artistRows) = try writer.read { db -> ([AlbumRow], Set<String>, [ArtistRow]) in
            var albumRows: [AlbumRow] = []
            if !albumScalars.isEmpty {
                var sql = """
                    SELECT a.ordinal, t.raw, t.original, t.latin, t.initials, t.semantic, t.pinyin,
                           r.raw, r.original, r.latin, r.initials, r.semantic, r.pinyin
                    FROM collectionSearchAlbum a
                    JOIN collectionSearchTextVersion t ON t.id = a.titleVersion
                    JOIN collectionSearchTextVersion r ON r.id = a.artistVersion
                    WHERE a.space = ?
                    """
                var arguments: StatementArguments = [space]
                for scalar in albumScalars {
                    sql += """
                         AND EXISTS (SELECT 1 FROM collectionSearchPosting p
                            WHERE p.space = ? AND p.scalar = ? AND p.version IN (a.titleVersion, a.artistVersion))
                        """
                    arguments += [space, Int64(scalar.value)]
                }
                sql += " ORDER BY a.ordinal"
                let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try rows.next() {
                    albumRows.append((ordinal: row[0], title: Self.prepared(row, from: 1), artist: Self.prepared(row, from: 7)))
                }
            }
            var related = Set<String>()
            for album in relatedAlbums where !related.contains(album.id) {
                if try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM collectionSearchAlbum WHERE space = ? AND albumID = ?)
                    """, arguments: [space, album.id]) == true {
                    related.insert(album.id)
                }
            }
            var artistRows: [ArtistRow] = []
            if !artistScalars.isEmpty {
                var sql = """
                    SELECT a.ordinal, t.raw, t.original, t.latin, t.initials, t.semantic, t.pinyin
                    FROM collectionSearchArtist a JOIN collectionSearchTextVersion t ON t.id = a.version
                    WHERE a.space = ?
                    """
                var arguments: StatementArguments = [space]
                for scalar in artistScalars {
                    sql += """
                         AND EXISTS (SELECT 1 FROM collectionSearchPosting p
                            WHERE p.space = ? AND p.scalar = ? AND p.version = a.version)
                        """
                    arguments += [space, Int64(scalar.value)]
                }
                sql += " ORDER BY a.ordinal"
                let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try rows.next() {
                    artistRows.append((ordinal: row[0], text: Self.prepared(row, from: 1)))
                }
            }
            return (albumRows, related, artistRows)
        }

        lastAlbumCandidateCount = albumRows.count
        var ranked: [(Album, Int)] = []
        for row in albumRows {
            guard !isCancelled() else { return Output(albums: [], artists: []) }
            let titleScore = matcher.score(prepared: row.title).map { $0 + 20 } ?? 0
            let artistScore = matcher.score(prepared: row.artist).map { $0 + 10 } ?? 0
            let score = max(titleScore, artistScore)
            if score > 0 { ranked.append((albums[row.ordinal], score)) }
        }
        var matchedAlbums = ranked.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map(\.0)
        var seen = Set(matchedAlbums.map(\.id))
        matchedAlbums += relatedAlbums.filter { relatedIDs.contains($0.id) && seen.insert($0.id).inserted }
        let words = semanticQuery.split(separator: " ")
        let matchedArtists = artistRows.compactMap { row -> Artist? in
            let text = row.text
            let matches = semanticArtists
                ? text.semantic.contains(semanticQuery) || (words.count > 1 && words.allSatisfy { text.semantic.contains($0) })
                : text.raw.localizedCaseInsensitiveContains(matcher.rawQuery)
            return matches ? artists[row.ordinal] : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Output(albums: matchedAlbums, artists: matchedArtists)
    }

    private static func scalars(_ query: String, alphanumericOnly: Bool) -> [Unicode.Scalar] {
        let characters = Set(query.unicodeScalars.filter {
            alphanumericOnly ? CharacterSet.alphanumerics.contains($0) : !CharacterSet.whitespacesAndNewlines.contains($0)
        })
        return characters.sorted { $0.value < $1.value }
    }

    private static func prepared(_ row: Row, from start: Int) -> LibrarySearchTextMatcher.PreparedText {
        LibrarySearchTextMatcher.PreparedText(
            raw: row[start], original: row[start + 1], latin: row[start + 2], initials: row[start + 3],
            semantic: row[start + 4], includesPinyin: (row[start + 5] as Int) != 0
        )
    }

    // MARK: - Preparation

    /// 两个数组共用同一块存储(与原先的 `sharesStorage` 相同)。
    private static func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    /// 备忘的键:规范等价的写法算同一段(与字典按 `String` 相等一致)。
    static func textKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private func prepare(
        albums nextAlbums: [Album], artists nextArtists: [Artist], includesPinyin: Bool, isCancelled: () -> Bool
    ) throws -> Bool {
        let space = space
        do {
            if !Self.sharesStorage(albums, nextAlbums) || (includesPinyin && !albumIncludesPinyin) {
                // 被取消时整批回滚,旧的行留着(与内存版一样:没排完就不换)。
                try writer.write { db in
                    let memo = MemoContext(db: db, space: space)
                    try db.execute(sql: "DELETE FROM collectionSearchAlbum WHERE space = ?", arguments: [space])
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO collectionSearchAlbum (space, ordinal, albumID, titleVersion, artistVersion)
                        VALUES (?, ?, ?, ?, ?)
                        """)
                    for (index, album) in nextAlbums.enumerated() {
                        guard !isCancelled() else { throw CancellationError() }
                        let title = try autoreleasepool { try memo.prepared(album.title, includesPinyin: includesPinyin) }
                        let artist = try autoreleasepool {
                            try memo.prepared(album.artistName ?? "", includesPinyin: includesPinyin)
                        }
                        try insert.execute(arguments: [space, index, album.id, title, artist])
                    }
                }
                albums = nextAlbums
                albumIncludesPinyin = includesPinyin
                preparationCount += 1
            }
            if !Self.sharesStorage(artists, nextArtists) {
                try writer.write { db in
                    let memo = MemoContext(db: db, space: space)
                    try db.execute(sql: "DELETE FROM collectionSearchArtist WHERE space = ?", arguments: [space])
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO collectionSearchArtist (space, ordinal, version) VALUES (?, ?, ?)
                        """)
                    for (index, artist) in nextArtists.enumerated() {
                        guard !isCancelled() else { throw CancellationError() }
                        let version = try autoreleasepool { try memo.prepared(artist.name, includesPinyin: false) }
                        try insert.execute(arguments: [space, index, version])
                    }
                }
                artists = nextArtists
                preparationCount += 1
            }
        } catch is CancellationError {
            return false
        }
        try writer.write { db in
            let memoCount = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM collectionSearchMemo WHERE space = ?", arguments: [space]
            ) ?? 0
            if memoCount > max(1_024, 2 * (nextAlbums.count * 2 + nextArtists.count)) {
                try Self.trim(space: space, in: db)
            }
        }
        return true
    }

    /// 备忘只留眼前专辑、艺人用到的文本;没人指向的版本连同倒排一起删掉。
    private static func trim(space: String, in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM collectionSearchMemo WHERE space = ?1 AND textKey NOT IN (
                SELECT v.textKey FROM collectionSearchAlbum a JOIN collectionSearchTextVersion v
                    ON v.id IN (a.titleVersion, a.artistVersion) WHERE a.space = ?1
                UNION
                SELECT v.textKey FROM collectionSearchArtist a JOIN collectionSearchTextVersion v
                    ON v.id = a.version WHERE a.space = ?1)
            """, arguments: [space])
        try db.execute(sql: """
            DELETE FROM collectionSearchTextVersion WHERE space = ?1
              AND id NOT IN (SELECT version FROM collectionSearchMemo WHERE space = ?1)
              AND id NOT IN (SELECT titleVersion FROM collectionSearchAlbum WHERE space = ?1)
              AND id NOT IN (SELECT artistVersion FROM collectionSearchAlbum WHERE space = ?1)
              AND id NOT IN (SELECT version FROM collectionSearchArtist WHERE space = ?1)
            """, arguments: [space])
        try db.execute(sql: """
            DELETE FROM collectionSearchPosting WHERE space = ?1
              AND version NOT IN (SELECT id FROM collectionSearchTextVersion WHERE space = ?1)
            """, arguments: [space])
    }

    // MARK: - Rows (albums and artists from the library catalog)

    /// 专辑、艺人一行:id 与参与预处理的文本(专辑名、专辑艺人;艺人名)。
    public struct CollectionRow: Sendable {
        public let id: String
        public let text: String
        /// 专辑的专辑艺人(没有时空串);艺人行不用。
        public let secondary: String

        public init(id: String, text: String, secondary: String = "") {
            self.id = id
            self.text = text
            self.secondary = secondary
        }
    }

    /// `searchRows` 的结果:专辑、艺人的 id,先后与 `search` 给的那份相同。`relatedAlbumIDs` 里排上的那几张
    /// 在 `relatedAlbumIDs` 里列出(调用方手里有那几张专辑本身)。
    public struct RowsOutput: Sendable, Equatable {
        public let albumIDs: [String]
        public let artistIDs: [String]
    }

    /// 同 `search(query:albums:artists:...)`,只是专辑、艺人不从内存里的数组来、也不留数组(6c 单元 4 U7):
    /// `albumRows` / `artistRows` 按块给出可见专辑(专辑墙的先后)与可见艺人(艺人列表的先后),块号从 0 起,
    /// 空块表示完了;`generation` 变了(曲库目录变了)或要拼音而上次没备拼音时重排,规则与按数组时逐条相同。
    /// 打分、同分时的先后(专辑名本地化比较,再按专辑墙的先后;艺人名标准比较,再按艺人列表的先后)也相同。
    /// 一个实例只用这一种准备法。
    public func searchRows(
        query: String,
        generation: Int64,
        albumRows: (Int) throws -> [CollectionRow],
        artistRows: (Int) throws -> [CollectionRow],
        relatedAlbumIDs: [String] = [],
        semanticArtists: Bool = false,
        includePinyin: Bool = true,
        isCancelled: () -> Bool = { false }
    ) throws -> RowsOutput {
        let empty = RowsOutput(albumIDs: [], artistIDs: [])
        let matcher = LibrarySearchTextMatcher(query: query)
        guard !matcher.rawQuery.isEmpty, !isCancelled(),
              try prepareRows(
                generation: generation, albumRows: albumRows, artistRows: artistRows,
                includesPinyin: includePinyin && matcher.requiresPinyinCandidates, isCancelled: isCancelled
              ) else { return empty }

        let space = space
        let albumScalars = Self.scalars(matcher.normalizedQuery, alphanumericOnly: true)
        let semanticQuery = ListeningSpaceSearchPolicy.normalized(query)
        let artistScalars = Self.scalars(semanticQuery, alphanumericOnly: false)
        typealias Prepared = LibrarySearchTextMatcher.PreparedText
        let rowText = Self.rowTextTable
        let (albumRows, relatedIDs, artistRows) = try writer.read { db
            -> ([(id: String, name: String, title: Prepared, artist: Prepared)], Set<String>,
                [(id: String, name: String, text: Prepared)]) in
            var albums: [(id: String, name: String, title: Prepared, artist: Prepared)] = []
            if !albumScalars.isEmpty {
                var sql = """
                    SELECT a.albumID, o.text, t.raw, t.original, t.latin, t.initials, t.semantic, t.pinyin,
                           r.raw, r.original, r.latin, r.initials, r.semantic, r.pinyin
                    FROM collectionSearchAlbum a
                    JOIN \(rowText) o ON o.space = a.space AND o.kind = 0 AND o.ordinal = a.ordinal
                    JOIN collectionSearchTextVersion t ON t.id = a.titleVersion
                    JOIN collectionSearchTextVersion r ON r.id = a.artistVersion
                    WHERE a.space = ?
                    """
                var arguments: StatementArguments = [space]
                for scalar in albumScalars {
                    sql += """
                         AND EXISTS (SELECT 1 FROM collectionSearchPosting p
                            WHERE p.space = ? AND p.scalar = ? AND p.version IN (a.titleVersion, a.artistVersion))
                        """
                    arguments += [space, Int64(scalar.value)]
                }
                sql += " ORDER BY a.ordinal"
                let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try rows.next() {
                    albums.append((id: row[0], name: row[1], title: Self.prepared(row, from: 2),
                                   artist: Self.prepared(row, from: 8)))
                }
            }
            var related = Set<String>()
            for id in relatedAlbumIDs where !related.contains(id) {
                if try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM collectionSearchAlbum WHERE space = ? AND albumID = ?)
                    """, arguments: [space, id]) == true {
                    related.insert(id)
                }
            }
            var artists: [(id: String, name: String, text: Prepared)] = []
            if !artistScalars.isEmpty {
                var sql = """
                    SELECT o.rowID, o.text, t.raw, t.original, t.latin, t.initials, t.semantic, t.pinyin
                    FROM collectionSearchArtist a
                    JOIN \(rowText) o ON o.space = a.space AND o.kind = 1 AND o.ordinal = a.ordinal
                    JOIN collectionSearchTextVersion t ON t.id = a.version
                    WHERE a.space = ?
                    """
                var arguments: StatementArguments = [space]
                for scalar in artistScalars {
                    sql += """
                         AND EXISTS (SELECT 1 FROM collectionSearchPosting p
                            WHERE p.space = ? AND p.scalar = ? AND p.version = a.version)
                        """
                    arguments += [space, Int64(scalar.value)]
                }
                sql += " ORDER BY a.ordinal"
                let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try rows.next() {
                    artists.append((id: row[0], name: row[1], text: Self.prepared(row, from: 2)))
                }
            }
            return (albums, related, artists)
        }

        lastAlbumCandidateCount = albumRows.count
        var ranked: [(id: String, title: String, score: Int)] = []
        for row in albumRows {
            guard !isCancelled() else { return empty }
            let titleScore = matcher.score(prepared: row.title).map { $0 + 20 } ?? 0
            let artistScore = matcher.score(prepared: row.artist).map { $0 + 10 } ?? 0
            let score = max(titleScore, artistScore)
            if score > 0 { ranked.append((row.id, row.name, score)) }
        }
        var albumIDs = ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }.map(\.id)
        var seen = Set(albumIDs)
        albumIDs += relatedAlbumIDs.filter { relatedIDs.contains($0) && seen.insert($0).inserted }
        let words = semanticQuery.split(separator: " ")
        let artistIDs = artistRows.compactMap { row -> (id: String, name: String)? in
            let text = row.text
            let matches = semanticArtists
                ? text.semantic.contains(semanticQuery) || (words.count > 1 && words.allSatisfy { text.semantic.contains($0) })
                : text.raw.localizedCaseInsensitiveContains(matcher.rawQuery)
            return matches ? (row.id, row.name) : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        return RowsOutput(albumIDs: albumIDs, artistIDs: artistIDs)
    }

    private func prepareRows(
        generation: Int64,
        albumRows: (Int) throws -> [CollectionRow],
        artistRows: (Int) throws -> [CollectionRow],
        includesPinyin: Bool,
        isCancelled: () -> Bool
    ) throws -> Bool {
        let space = space
        let regroups = rowsGeneration != generation
        var albumCount = 0
        var artistCount = 0
        do {
            if regroups || (includesPinyin && !rowsAlbumPinyin) {
                try writer.write { db in
                    try Self.createRowTextTable(in: db)
                    // 别的实例按行准备时留下的(每次运行换新的 space,同一时刻只有一个这样的实例)。
                    try db.execute(sql: "DELETE FROM \(Self.rowTextTable) WHERE space != ?", arguments: [space])
                    let memo = MemoContext(db: db, space: space)
                    try db.execute(sql: "DELETE FROM collectionSearchAlbum WHERE space = ?", arguments: [space])
                    try db.execute(sql: "DELETE FROM \(Self.rowTextTable) WHERE space = ? AND kind = 0", arguments: [space])
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO collectionSearchAlbum (space, ordinal, albumID, titleVersion, artistVersion)
                        VALUES (?, ?, ?, ?, ?)
                        """)
                    let insertText = try db.makeStatement(sql: """
                        INSERT INTO \(Self.rowTextTable) (space, kind, ordinal, rowID, text) VALUES (?, 0, ?, ?, ?)
                        """)
                    var chunk = 0
                    while true {
                        let rows = try albumRows(chunk)
                        guard !rows.isEmpty else { break }
                        for row in rows {
                            guard !isCancelled() else { throw CancellationError() }
                            let title = try autoreleasepool { try memo.prepared(row.text, includesPinyin: includesPinyin) }
                            let artist = try autoreleasepool { try memo.prepared(row.secondary, includesPinyin: includesPinyin) }
                            try insert.execute(arguments: [space, albumCount, row.id, title, artist])
                            try insertText.execute(arguments: [space, albumCount, row.id, row.text])
                            albumCount += 1
                        }
                        chunk += 1
                    }
                }
                rowsAlbumPinyin = includesPinyin
                preparationCount += 1
            }
            if regroups {
                try writer.write { db in
                    let memo = MemoContext(db: db, space: space)
                    try db.execute(sql: "DELETE FROM collectionSearchArtist WHERE space = ?", arguments: [space])
                    try db.execute(sql: "DELETE FROM \(Self.rowTextTable) WHERE space = ? AND kind = 1", arguments: [space])
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO collectionSearchArtist (space, ordinal, version) VALUES (?, ?, ?)
                        """)
                    let insertText = try db.makeStatement(sql: """
                        INSERT INTO \(Self.rowTextTable) (space, kind, ordinal, rowID, text) VALUES (?, 1, ?, ?, ?)
                        """)
                    var chunk = 0
                    while true {
                        let rows = try artistRows(chunk)
                        guard !rows.isEmpty else { break }
                        for row in rows {
                            guard !isCancelled() else { throw CancellationError() }
                            let version = try autoreleasepool { try memo.prepared(row.text, includesPinyin: false) }
                            try insert.execute(arguments: [space, artistCount, version])
                            try insertText.execute(arguments: [space, artistCount, row.id, row.text])
                            artistCount += 1
                        }
                        chunk += 1
                    }
                }
                rowsGeneration = generation
                preparationCount += 1
            }
        } catch is CancellationError {
            // 没排完不换(专辑排完了、艺人没排完时下一次整代重排)。
            if regroups { rowsGeneration = nil }
            return false
        }
        if regroups {
            try writer.write { db in
                let memoCount = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM collectionSearchMemo WHERE space = ?", arguments: [space]
                ) ?? 0
                if memoCount > max(1_024, 2 * (albumCount * 2 + artistCount)) {
                    try Self.trim(space: space, in: db)
                }
            }
        }
        return true
    }

    /// 写事务里的文本备忘:原先的 `prepared(_:includesPinyin:)`,返回指向的版本。
    private struct MemoContext {
        let db: Database
        let space: String

        func prepared(_ text: String, includesPinyin: Bool) throws -> Int64 {
            let key = LibraryCollectionSearchStore.textKey(text)
            if let row = try Row.fetchOne(db, sql: """
                SELECT m.version, v.pinyin FROM collectionSearchMemo m JOIN collectionSearchTextVersion v ON v.id = m.version
                WHERE m.space = ? AND m.textKey = ?
                """, arguments: [space, key]) {
                let version: Int64 = row[0]
                let pinyin: Int = row[1]
                if pinyin != 0 || !includesPinyin { return version }
            }
            let value = LibrarySearchTextMatcher.PreparedText(text, includesPinyin: includesPinyin)
            let version = try store(value, key: key)
            try db.execute(sql: """
                INSERT INTO collectionSearchMemo (space, textKey, version) VALUES (?, ?, ?)
                ON CONFLICT(space, textKey) DO UPDATE SET version = excluded.version
                """, arguments: [space, key, version])
            return version
        }

        /// 一份预处理文本(文本 + 是否带拼音)写一次;同一份已经在(之前预处理过、后来被备忘换掉)时
        /// 换成这次的内容,倒排跟着换。
        private func store(_ value: LibrarySearchTextMatcher.PreparedText, key: String) throws -> Int64 {
            let pinyin = value.includesPinyin ? 1 : 0
            let version: Int64
            if let existing = try Int64.fetchOne(db, sql: """
                SELECT id FROM collectionSearchTextVersion WHERE space = ? AND textKey = ? AND pinyin = ?
                """, arguments: [space, key, pinyin]) {
                // 被行指着的旧版本内容不能改(艺人行留着当时那份):只有没人指向时才原地换。
                let referenced = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM collectionSearchArtist WHERE space = ?1 AND version = ?2)
                        OR EXISTS (SELECT 1 FROM collectionSearchAlbum WHERE space = ?1 AND (titleVersion = ?2 OR artistVersion = ?2))
                    """, arguments: [space, existing]) ?? false
                if referenced, try Self.matches(existing, value, in: db) { return existing }
                if referenced {
                    // 同一键同一拼音状态、内容不同(规范等价的另一种写法):另存一份,不动旧的。
                    try db.execute(sql: """
                        UPDATE collectionSearchTextVersion SET textKey = textKey || char(1) || id WHERE id = ?
                        """, arguments: [existing])
                } else {
                    try db.execute(sql: "DELETE FROM collectionSearchPosting WHERE space = ? AND version = ?", arguments: [space, existing])
                    try db.execute(sql: "DELETE FROM collectionSearchTextVersion WHERE id = ?", arguments: [existing])
                }
            }
            try db.execute(sql: """
                INSERT INTO collectionSearchTextVersion (space, textKey, pinyin, raw, original, latin, initials, semantic)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [space, key, pinyin, value.raw, value.original, value.latin, value.initials, value.semantic])
            version = db.lastInsertedRowID
            let posting = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO collectionSearchPosting (space, scalar, version) VALUES (?, ?, ?)
                """)
            for scalar in value.characters {
                try posting.execute(arguments: [space, Int64(scalar.value), version])
            }
            return version
        }

        private static func matches(_ version: Int64, _ value: LibrarySearchTextMatcher.PreparedText, in db: Database) throws -> Bool {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT raw, original, latin, initials, semantic FROM collectionSearchTextVersion WHERE id = ?
                """, arguments: [version]) else { return false }
            return row[0] == value.raw && row[1] == value.original && row[2] == value.latin
                && row[3] == value.initials && row[4] == value.semantic
        }
    }
}
