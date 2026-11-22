import CryptoKit
import Foundation
import GRDB

/// 分组派生依赖的 App 输入。任何一项变了都要整库重建(`setGroupingConfiguration`)。
public struct LibraryGroupingConfiguration: Sendable, Equatable {
    public var artistNames: ArtistNameConfiguration
    /// 本地化的「未知艺人」:进专辑身份与艺人 id 的哈希。
    public var unknownArtist: String
    public var classification: SpokenWordClassificationInputs
    public var genreSeparators: GenreSeparatorOptions

    public init(
        artistNames: ArtistNameConfiguration = .defaultValue,
        unknownArtist: String = "Unknown Artist",
        classification: SpokenWordClassificationInputs = .empty,
        genreSeparators: GenreSeparatorOptions = []
    ) {
        self.artistNames = artistNames.normalized()
        self.unknownArtist = unknownArtist
        self.classification = classification
        self.genreSeparators = genreSeparators
    }

    /// 记进 meta 的指纹:下次打开时比对,决定要不要整库重建。
    var fingerprint: String {
        var text = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        text += (try? encoder.encode(artistNames)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        text += "\u{1}" + unknownArtist
        text += "\u{1}" + classification.overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",")
        text += "\u{1}" + classification.collectionOnlySongIDs.sorted().joined(separator: ",")
        text += "\u{1}" + classification.catalogPathSourceIDs.sorted().joined(separator: ",")
        text += "\u{1}\(classification.itemFoldersRevision)\u{1}\(classification.separatesAmbient)"
        text += "\u{1}\(String(describing: classification.folderRules))"
        text += "\u{1}\(genreSeparators.rawValue)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 增量维护时收集的脏范围。
struct GroupingDirtySet {
    var titles: Set<String> = []
    var albumIDs: Set<String> = []
    var artistIDs: Set<String> = []
    var lookupArtistIDs: Set<String> = []
    var sources: Set<Int64> = []
    var sourcesWithRemovals: Set<Int64> = []
    var folders: Set<Int64> = []
    /// 有声书归书闭包的起点:(类别, 文件夹键) 与 (类别, 专辑键)。
    var bookFolderLinks: Set<String> = []
    var bookAlbumLinks: Set<String> = []
    /// 停用/启用源、换输入时整个书架重来。
    var allBooks = false
    var orphanBookRows: Set<Int64> = []
    var books: Bool { allBooks || !bookFolderLinks.isEmpty || !bookAlbumLinks.isEmpty || !orphanBookRows.isEmpty }

    var isEmpty: Bool {
        titles.isEmpty && albumIDs.isEmpty && artistIDs.isEmpty && lookupArtistIDs.isEmpty
            && sources.isEmpty && folders.isEmpty && !books
    }
}

/// 写事务内的分组维护:逐行派生(类别、艺人、流派、文件夹)立即算,依赖其他行的
/// (专辑艺人推断、专辑、艺人、有声书)按脏范围重跑参照实现。
struct GroupingMaintenance {
    let db: Database
    let configuration: LibraryGroupingConfiguration
    var dirty = GroupingDirtySet()
    /// 整库重建时按阶段流式处理,不再把下游的键攒进脏集合。
    var collectsDirty = true
    private var genreVerdicts: [String: ListeningContentKind] = [:]
    private var artistNamesMemo: [LibraryGroupingReference.DerivedIDMemo.ArtistNames: [(id: String, name: String)]] = [:]
    private var lookupMemo: [LibraryGroupingReference.ArtistResolutionFields: [String]] = [:]

    init(db: Database, configuration: LibraryGroupingConfiguration) {
        self.db = db
        self.configuration = configuration
    }

    static let spokenKinds = [LibraryCatalogContentKind.spokenWord.rawValue, LibraryCatalogContentKind.podcast.rawValue]

    /// 专辑艺人推断用的「目录」:扫描索引给文件夹的源用存下的父文件夹,其余用所在文件夹的键
    /// (同一个源里不同目录 ↔ 不同键,与按路径取目录的判定一致)。
    static let inferenceDirectorySQL = "CASE WHEN source.usesFolderParents = 1 THEN song.inferenceDirectory ELSE 'f' || song.folderKey END"

    /// 一行的逐行派生,纯函数(可以多核并行算)。
    struct RowValues: @unchecked Sendable {
        var kind: Int
        var artistIDs: [String]
        var lookupIDs: [String]
        var genres: [(id: String, name: String)]
        var folderPath: String
        var bookLinks: (folder: String?, album: String?)?
        var albumTitleKey: String?
    }

    static func rowValues(for song: Song, configuration: LibraryGroupingConfiguration) -> RowValues {
        let classification = configuration.classification
        let kind: Int
        if classification.collectionOnlySongIDs.contains(song.id) {
            kind = LibraryCatalogContentKind.collectionOnly.rawValue
        } else {
            var verdicts: [String: ListeningContentKind] = [:]
            switch classification.kind(
                songID: song.id, sourceID: song.sourceID, filePath: song.filePath, genre: song.genre,
                serverLibraryID: song.serverLibraryID, genreVerdicts: &verdicts
            ) {
            case .music: kind = LibraryCatalogContentKind.music.rawValue
            case .spokenWord: kind = LibraryCatalogContentKind.spokenWord.rawValue
            case .podcast: kind = LibraryCatalogContentKind.podcast.rawValue
            case .ambient: kind = LibraryCatalogContentKind.ambient.rawValue
            }
        }
        let artistIDs = LibraryGroupingReference.resolvedArtistNames(
            for: song, configuration: configuration.artistNames, unknownArtist: configuration.unknownArtist
        ).map { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
        let lookupIDs = LibraryGroupingReference.resolvedArtistIDs(
            for: song, configuration: configuration.artistNames, unknownArtist: configuration.unknownArtist
        )
        var genres: [(id: String, name: String)] = []
        if let genre = song.genre {
            for name in GenreTagValues.names(
                in: genre, alsoSplitting: configuration.genreSeparators,
                slashConvention: GenreSlashConvention.applies(to: song.fileFormat)
            ) {
                let id = LibraryGenreIndexBuilder.normalizedID(for: name)
                if !id.isEmpty { genres.append((id, name)) }
            }
        }
        let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RowValues(
            kind: kind,
            artistIDs: artistIDs,
            lookupIDs: lookupIDs,
            genres: genres,
            folderPath: AlbumArtistInferencePolicy.directory(ofPath: song.filePath),
            bookLinks: spokenKinds.contains(kind)
                ? SpokenWordBookGroupingRules.linkKeys(of: SpokenWordBookItem(song: song)) : nil,
            albumTitleKey: title?.isEmpty == false ? title : nil
        )
    }

    /// 一批歌的逐行派生,分到多个核上算。
    static func rowValues(for songs: [Song], configuration: LibraryGroupingConfiguration) -> [RowValues] {
        let slots = RowValueSlots(count: songs.count)
        let slices = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, songs.count / 64))
        let size = (songs.count + slices - 1) / slices
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            let start = slice * size
            let end = min(songs.count, start + size)
            guard start < end else { return }
            for index in start..<end { slots.set(index, rowValues(for: songs[index], configuration: configuration)) }
        }
        return slots.values
    }

    /// 一次性分配的裸内存:每个下标只由一个片写一次(并发写数组属性会触发独占访问检查)。
    private final class RowValueSlots: @unchecked Sendable {
        private let slots: UnsafeMutableBufferPointer<RowValues?>
        init(count: Int) {
            slots = .allocate(capacity: count)
            slots.initialize(repeating: nil)
        }
        deinit {
            slots.deinitialize()
            slots.deallocate()
        }
        func set(_ index: Int, _ value: RowValues) { slots[index] = value }
        var values: [RowValues] { slots.map { $0! } }
    }

    // MARK: - Before a row changes

    /// 记下这一行改动前所在的范围(旧标题、旧专辑、旧艺人、旧文件夹)。
    mutating func noteExisting(rowid: Int64) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT s.albumTitleKey, s.effectiveAlbumID, s.sourceKey, s.kind, s.folderKey, b.folderLink, b.albumLink
                FROM song s LEFT JOIN songBook b ON b.songRowid = s.rowid WHERE s.rowid = ?
                """,
            arguments: [rowid]
        ) else { return }
        if let title: String = row[0] { dirty.titles.insert(title) }
        if let album: String = row[1] { dirty.albumIDs.insert(album) }
        let sourceKey: Int64 = row[2]
        dirty.sources.insert(sourceKey)
        dirty.sourcesWithRemovals.insert(sourceKey)
        let kind: Int = row[3]
        if let link: String = row[5] { dirty.bookFolderLinks.insert("\(kind)\u{1}\(link)") }
        if let link: String = row[6] { dirty.bookAlbumLinks.insert("\(kind)\u{1}\(link)") }
        if Self.spokenKinds.contains(kind), row[5] as String? == nil, row[6] as String? == nil {
            // 独立成书的条目没有连接键:它所在的书只有它自己,删掉或改动后那本书要清掉。
            dirty.orphanBookRows.insert(rowid)
        }
        if let folder: Int64 = row[4] { dirty.folders.insert(folder) }
        for id in try String.fetchAll(db, sql: "SELECT artistID FROM songArtist WHERE songRowid = ?", arguments: [rowid]) {
            dirty.artistIDs.insert(id)
        }
        for id in try String.fetchAll(db, sql: "SELECT artistID FROM songArtistLookup WHERE songRowid = ?", arguments: [rowid]) {
            dirty.lookupArtistIDs.insert(id)
        }
    }

    mutating func removeDerivedRows(rowid: Int64) throws {
        for table in ["songArtist", "songArtistLookup", "songGenre"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE songRowid = ?", arguments: [rowid])
        }
        try db.execute(sql: "DELETE FROM songBook WHERE songRowid = ?", arguments: [rowid])
    }

    // MARK: - Per-row derivation

    /// 写入一行的逐行派生:类别、艺人(按名字与按查找 id)、流派、文件夹、有声书连接键。
    /// `fresh` 表示派生表里还没有这一行(整库重建、导入),省掉先删。
    mutating func writeRow(
        rowid: Int64, sourceKey: Int64, values: RowValues, fresh: Bool = false,
        current: (kind: Int, folderKey: Int64?)? = nil
    ) throws {
        if !fresh { try removeDerivedRows(rowid: rowid) }
        let folder = try folderKey(sourceKey: sourceKey, path: values.folderPath)
        let stored: (kind: Int, folderKey: Int64?)
        if let current {
            stored = current
        } else if let row = try Row.fetchOne(db, sql: "SELECT kind, folderKey FROM song WHERE rowid = ?", arguments: [rowid]) {
            stored = (row[0], row[1])
        } else {
            stored = (-1, nil)
        }
        // 类别是四条排序索引的首列:只在真变了时才写。
        if stored.kind != values.kind || stored.folderKey != folder {
            try db.cachedStatement(sql: "UPDATE song SET kind = ?, folderKey = ? WHERE rowid = ?")
                .execute(arguments: [values.kind, folder, rowid])
        }
        let insertArtist = try db.cachedStatement(sql: "INSERT INTO songArtist (songRowid, ordinal, artistID) VALUES (?, ?, ?)")
        for (ordinal, id) in values.artistIDs.enumerated() {
            try insertArtist.execute(arguments: [rowid, ordinal, id])
            if collectsDirty { dirty.artistIDs.insert(id) }
        }
        let insertLookup = try db.cachedStatement(sql: "INSERT OR IGNORE INTO songArtistLookup (songRowid, artistID) VALUES (?, ?)")
        for id in values.lookupIDs {
            try insertLookup.execute(arguments: [rowid, id])
            if collectsDirty { dirty.lookupArtistIDs.insert(id) }
        }
        let insertGenre = try db.cachedStatement(sql: "INSERT INTO songGenre (songRowid, ordinal, genreID, name) VALUES (?, ?, ?, ?)")
        for (ordinal, genre) in values.genres.enumerated() {
            try insertGenre.execute(arguments: [rowid, ordinal, genre.id, genre.name])
        }
        if let links = values.bookLinks {
            try db.cachedStatement(sql: """
                INSERT INTO songBook (songRowid, kind, folderLink, albumLink) VALUES (?, ?, ?, ?)
                """).execute(arguments: [rowid, values.kind, links.folder, links.album])
            if collectsDirty {
                if let link = links.folder { dirty.bookFolderLinks.insert("\(values.kind)\u{1}\(link)") }
                if let link = links.album { dirty.bookAlbumLinks.insert("\(values.kind)\u{1}\(link)") }
                if links.folder == nil, links.album == nil { dirty.orphanBookRows.insert(rowid) }
            }
        }
        if values.albumTitleKey == nil {
            try db.cachedStatement(sql: "UPDATE song SET effectiveAlbumArtist = NULL, effectiveAlbumID = NULL WHERE rowid = ?")
                .execute(arguments: [rowid])
        }
        if collectsDirty {
            dirty.folders.insert(folder)
            dirty.sources.insert(sourceKey)
            if let title = values.albumTitleKey { dirty.titles.insert(title) }
        }
    }

    /// 增量写入时的一行(只算这一首)。
    mutating func deriveRow(rowid: Int64, song: Song, sourceKey: Int64) throws {
        try writeRow(rowid: rowid, sourceKey: sourceKey, values: Self.rowValues(for: song, configuration: configuration))
    }

    /// 目录的文件夹:按「上一级 + 名字」逐级存,不存整条路径。路径写法与上一级加名字拼不回来
    /// (比如 "a//b")时原样记在 `oddPath`,保证不同的目录写法不会并成一个文件夹。
    struct FolderComponent: Hashable {
        let name: String
        let oddPath: String
    }

    static func folderChain(of path: String) -> [FolderComponent] {
        var chain: [String] = []
        var current: String? = path
        while let value = current {
            chain.append(value)
            current = parentFolder(of: value)
        }
        return chain.reversed().map { value in
            let name = folderName(of: value)
            let rebuilt = parentFolder(of: value).map { joinFolder($0, name) } ?? name
            return FolderComponent(name: name, oddPath: rebuilt == value ? "" : value)
        }
    }

    static func joinFolder(_ parent: String, _ name: String) -> String {
        if parent.isEmpty { return name }
        if parent == "/" { return "/" + name }
        return parent + "/" + name
    }

    private var folderCache: [String: Int64] = [:]

    /// 目录的文件夹行(连同各级上级),返回它的键。
    private mutating func folderKey(sourceKey: Int64, path: String) throws -> Int64 {
        let cacheKey = "\(sourceKey)\u{1}\(path)"
        if let cached = folderCache[cacheKey] { return cached }
        var parent: Int64 = 0
        for component in Self.folderChain(of: path) {
            if let key = try Int64.fetchOne(db, sql: """
                SELECT key FROM folder WHERE sourceKey = ? AND parentKey = ? AND name = ? AND oddPath = ?
                """, arguments: [sourceKey, parent, component.name, component.oddPath]) {
                parent = key
            } else {
                try db.execute(
                    sql: "INSERT INTO folder (sourceKey, parentKey, name, oddPath) VALUES (?, ?, ?, ?)",
                    arguments: [sourceKey, parent, component.name, component.oddPath]
                )
                parent = db.lastInsertedRowID
            }
        }
        if folderCache.count > 50_000 { folderCache.removeAll(keepingCapacity: true) }
        folderCache[cacheKey] = parent
        return parent
    }

    /// 上一级目录;根("" 或 "/")没有上级。
    static func parentFolder(of path: String) -> String? {
        guard !path.isEmpty, path != "/" else { return nil }
        return AlbumArtistInferencePolicy.directory(ofPath: path)
    }

    static func folderName(of path: String) -> String {
        guard !path.isEmpty, path != "/" else { return path }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Scoped recomputation

    mutating func flush() throws {
        typealias Profile = LibraryCatalogImportProfile
        try Profile.measure("flush.authority") { try refreshDirectoryAuthority() }
        try Profile.measure("flush.titles") { try regroupTitles() }
        try Profile.measure("flush.albums") { try rebuildAlbums() }
        try Profile.measure("flush.artists") { try rebuildArtists() }
        try Profile.measure("flush.artistStats") { try rebuildArtistStats() }
        if dirty.books { try Profile.measure("flush.books") { try rebuildBooks() } }
        try Profile.measure("flush.folders") { try recountFolders() }
        dirty = GroupingDirtySet()
    }

    /// 「源里至少有两个不同目录才有目录权威」。权威翻转时这个源的所有标题都要重推断。
    private mutating func refreshDirectoryAuthority() throws {
        for sourceKey in dirty.sources {
            let current = try Int.fetchOne(
                db, sql: "SELECT hasDirectoryAuthority FROM source WHERE key = ?", arguments: [sourceKey]
            ) ?? 0
            // 已有权威时只有删除、移动才可能失去它。
            if current == 1, !dirty.sourcesWithRemovals.contains(sourceKey) { continue }
            let distinct = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (SELECT DISTINCT \(Self.inferenceDirectorySQL) AS directory
                FROM song JOIN source ON source.key = song.sourceKey
                WHERE song.sourceKey = ? AND directory IS NOT NULL LIMIT 2)
                """, arguments: [sourceKey]) ?? 0
            let next = distinct >= 2 ? 1 : 0
            guard next != current else { continue }
            try db.execute(sql: "UPDATE source SET hasDirectoryAuthority = ? WHERE key = ?", arguments: [next, sourceKey])
            for title in try String.fetchAll(db, sql: """
                SELECT DISTINCT albumTitleKey FROM song WHERE sourceKey = ? AND albumTitleKey IS NOT NULL
                """, arguments: [sourceKey]) {
                dirty.titles.insert(title)
            }
        }
    }

    /// 专辑艺人推断只在同一个(去空白的)专辑标题之内互相影响:按标题分批重跑,
    /// 回写 `effectiveAlbumArtist` / `effectiveAlbumID`。
    private mutating func regroupTitles() throws {
        guard !dirty.titles.isEmpty else { return }
        try regroupTitles(dirty.titles.sorted())
    }

    mutating func regroupTitles(_ titles: [String]) throws {
        let authoritative = Set(try String.fetchAll(db, sql: "SELECT id FROM source WHERE hasDirectoryAuthority = 1"))
        let update = try db.makeStatement(sql: "UPDATE song SET effectiveAlbumArtist = ?, effectiveAlbumID = ? WHERE rowid = ?")
        for chunk in LibraryCatalog.chunks(of: titles, size: 200) {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(LibraryCatalogSongCodec.selectColumns), \(Self.inferenceDirectorySQL),
                           song.effectiveAlbumArtist, song.effectiveAlbumID
                    \(LibraryCatalogSongCodec.selectFrom)
                    WHERE song.albumTitleKey IN (\(LibraryCatalog.placeholders(chunk.count)))
                    ORDER BY song.orderKey, song.id
                    """,
                arguments: StatementArguments(Array(chunk))
            )
            var songs: [Song] = []
            var tracks: [AlbumArtistInferencePolicy.Track] = []
            songs.reserveCapacity(rows.count)
            tracks.reserveCapacity(rows.count)
            let directoryColumn = LibraryCatalogSongCodec.Column.extra + 1
            for row in rows {
                let song = try LibraryCatalogSongCodec.decode(row)
                songs.append(song)
                tracks.append(AlbumArtistInferencePolicy.Track(song: song, directory: row[directoryColumn]))
            }
            let inferred = AlbumArtistInferencePolicy.inferredAlbumArtists(
                for: tracks,
                directoryAuthoritativeSourceIDs: authoritative,
                configuration: configuration.artistNames
            )
            for (index, row) in rows.enumerated() {
                let song = songs[index]
                let effectiveArtist = inferred[song.id]
                let albumID = AlbumGroupingPolicy.identity(
                    albumTitle: song.albumTitle,
                    albumArtistName: effectiveArtist ?? song.albumArtistName,
                    trackArtistName: song.artistName,
                    unknownArtistName: configuration.unknownArtist
                ).map { LibraryGroupingReference.hashID("\($0.artistName):\($0.albumTitle)") }
                let storedArtist: String? = row[directoryColumn + 1]
                let storedAlbum: String? = row[directoryColumn + 2]
                if collectsDirty, let albumID { dirty.albumIDs.insert(albumID) }
                guard storedArtist != effectiveArtist || storedAlbum != albumID else { continue }
                let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                try update.execute(arguments: [effectiveArtist, albumID, rowid])
                guard collectsDirty else { continue }
                if let storedAlbum { dirty.albumIDs.insert(storedAlbum) }
                if storedAlbum != albumID {
                    for id in try String.fetchAll(db, sql: "SELECT artistID FROM songArtist WHERE songRowid = ?", arguments: [rowid]) {
                        dirty.artistIDs.insert(id)
                    }
                }
            }
        }
    }

    /// 一组歌(库内顺序)与它们已存的推断结果:参照实现 `computeAlbumsAndArtists` 的输入。
    private func fetchSongs(sql whereSQL: String, arguments: StatementArguments) throws -> (songs: [Song], inference: [String: String], orderKeys: [String: Int64]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns), song.effectiveAlbumArtist, song.orderKey
                \(LibraryCatalogSongCodec.selectFrom) WHERE \(whereSQL) ORDER BY song.orderKey, song.id
                """,
            arguments: arguments
        )
        var songs: [Song] = []
        var inference: [String: String] = [:]
        var orderKeys: [String: Int64] = [:]
        songs.reserveCapacity(rows.count)
        let artistColumn = LibraryCatalogSongCodec.Column.extra + 1
        for row in rows {
            let song = try LibraryCatalogSongCodec.decode(row)
            songs.append(song)
            if let artist: String = row[artistColumn] { inference[song.id] = artist }
            orderKeys[song.id] = row[artistColumn + 1]
        }
        return (songs, inference, orderKeys)
    }

    private mutating func rebuildAlbums() throws {
        guard !dirty.albumIDs.isEmpty else { return }
        try rebuildAlbums(dirty.albumIDs.sorted())
    }

    mutating func rebuildAlbums(_ albumIDs: [String]) throws {
        let upsert = try db.makeStatement(sql: """
            INSERT INTO album (id, title, titleKey, artistID, artistName, artistKey, year, genre, sourceID,
                               firstOrderKey, firstSongID, songCount, duration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, titleKey = excluded.titleKey,
                artistID = excluded.artistID, artistName = excluded.artistName, artistKey = excluded.artistKey,
                year = excluded.year, genre = excluded.genre, sourceID = excluded.sourceID,
                firstOrderKey = excluded.firstOrderKey, firstSongID = excluded.firstSongID,
                songCount = excluded.songCount, duration = excluded.duration
            """)
        for albumID in albumIDs {
            let group = try fetchSongs(sql: "song.effectiveAlbumID = ?", arguments: [albumID])
            try db.execute(sql: "DELETE FROM albumSourceStat WHERE albumID = ?", arguments: [albumID])
            try db.execute(sql: "DELETE FROM albumArtistCredit WHERE albumID = ?", arguments: [albumID])
            guard let first = group.songs.first,
                  let album = LibraryGroupingReference.computeAlbumsAndArtists(
                    songs: group.songs,
                    configuration: configuration.artistNames,
                    folders: .empty,
                    inferredAlbumArtists: group.inference,
                    unknownArtist: configuration.unknownArtist
                  ).albums.first(where: { $0.id == albumID }) else {
                try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [albumID])
                continue
            }
            try upsert.execute(arguments: [
                album.id, album.title, LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: album.title)),
                album.artistID ?? "", album.artistName ?? "",
                LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: album.artistName ?? "")),
                album.year, album.genre, album.sourceID, group.orderKeys[first.id] ?? 0, first.id,
                album.songCount, album.totalDuration,
            ])
            try db.execute(sql: """
                INSERT INTO albumSourceStat (albumID, sourceKey, kind, songCount, duration, maxDateAdded)
                SELECT effectiveAlbumID, sourceKey, kind, count(*), total(durationKey), max(dateAdded)
                FROM song WHERE effectiveAlbumID = ? GROUP BY sourceKey, kind
                """, arguments: [albumID])
            let insertCredit = try db.cachedStatement(sql: """
                INSERT INTO albumArtistCredit (albumID, ordinal, artistID, name) VALUES (?, ?, ?, ?)
                """)
            for (ordinal, credit) in Self.parsedCredits(for: album, configuration: configuration.artistNames).enumerated() {
                try insertCredit.execute(arguments: [album.id, ordinal, credit.id, credit.name])
            }
        }
    }

    /// `AlbumArtistIndexBuilder` 里专辑艺人不是可见曲目艺人时的那一支(按名字拆)。
    /// 是可见曲目艺人时只用专辑自己的艺人 id,那一支在查询时判断。
    static func parsedCredits(for album: Album, configuration: ArtistNameConfiguration) -> [(id: String, name: String?)] {
        guard let originalID = album.artistID, !originalID.isEmpty else { return [] }
        let names = ArtistNameParser.names(rawName: album.artistName, configuration: configuration.normalized())
        if names.isEmpty { return [(originalID, nil)] }
        if names.count == 1,
           ArtistIdentityPolicy.groupingKey(names[0]) == ArtistIdentityPolicy.groupingKey(album.artistName ?? "") {
            return [(originalID, names[0])]
        }
        return names.map { (LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)), $0) }
    }

    private mutating func rebuildArtists() throws {
        guard !dirty.artistIDs.isEmpty else { return }
        try rebuildArtists(dirty.artistIDs.sorted())
    }

    mutating func rebuildArtists(_ artistIDs: [String]) throws {
        let upsert = try db.makeStatement(sql: """
            INSERT INTO artist (id, name, nameKey, firstOrderKey, firstOrdinal, songCount, albumCount, thumbnailPath)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, nameKey = excluded.nameKey,
                firstOrderKey = excluded.firstOrderKey, firstOrdinal = excluded.firstOrdinal,
                songCount = excluded.songCount, albumCount = excluded.albumCount, thumbnailPath = excluded.thumbnailPath
            """)
        for artistID in artistIDs {
            let group = try fetchSongs(
                sql: "song.rowid IN (SELECT songRowid FROM songArtist WHERE artistID = ?)", arguments: [artistID]
            )
            guard let artist = LibraryGroupingReference.computeAlbumsAndArtists(
                songs: group.songs,
                configuration: configuration.artistNames,
                folders: .empty,
                inferredAlbumArtists: group.inference,
                unknownArtist: configuration.unknownArtist
            ).artists.first(where: { $0.id == artistID }) else {
                try db.execute(sql: "DELETE FROM artist WHERE id = ?", arguments: [artistID])
                continue
            }
            let first = group.songs[0]
            let ordinal = try Int.fetchOne(db, sql: """
                SELECT min(ordinal) FROM songArtist WHERE artistID = ? AND songRowid = (SELECT rowid FROM song WHERE id = ?)
                """, arguments: [artistID, first.id]) ?? 0
            try upsert.execute(arguments: [
                artist.id, artist.name, LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: artist.name)),
                group.orderKeys[first.id] ?? 0, ordinal, artist.songCount, artist.albumCount, artist.thumbnailPath,
            ])
        }
    }

    /// 整库重建:一条语句重算全部按源、按类别的艺人统计。
    func rebuildAllArtistStats() throws {
        try db.execute(sql: """
            DELETE FROM artistSourceStat;
            INSERT INTO artistSourceStat (artistID, sourceKey, kind, songCount)
            SELECT l.artistID, s.sourceKey, s.kind, count(*) FROM songArtistLookup l
            JOIN song s ON s.rowid = l.songRowid GROUP BY l.artistID, s.sourceKey, s.kind;
            """)
    }

    /// 整库重建:全部文件夹的直接歌曲数。
    func recountAllFolders() throws {
        try db.execute(sql: """
            UPDATE folder SET songCount = (SELECT count(*) FROM song WHERE song.folderKey = folder.key)
            """)
    }

    private mutating func rebuildArtistStats() throws {
        guard !dirty.lookupArtistIDs.isEmpty else { return }
        for chunk in LibraryCatalog.chunks(of: dirty.lookupArtistIDs.sorted()) {
            let placeholders = LibraryCatalog.placeholders(chunk.count)
            try db.execute(
                sql: "DELETE FROM artistSourceStat WHERE artistID IN (\(placeholders))",
                arguments: StatementArguments(Array(chunk))
            )
            try db.execute(
                sql: """
                    INSERT INTO artistSourceStat (artistID, sourceKey, kind, songCount)
                    SELECT l.artistID, s.sourceKey, s.kind, count(*) FROM songArtistLookup l
                    JOIN song s ON s.rowid = l.songRowid
                    WHERE l.artistID IN (\(placeholders)) GROUP BY l.artistID, s.sourceKey, s.kind
                    """,
                arguments: StatementArguments(Array(chunk))
            )
        }
    }

    /// 有声书/播客的归书规则会读同一文件夹、同一专辑的其他条目:从改动的条目出发,沿文件夹键与
    /// 专辑键(`SpokenWordBookGroupingRules.linkKeys`)求闭包,只对闭包里的可见条目重跑参照实现。
    /// 停用/启用源或换输入时整个书架重来。
    mutating func rebuildBooks() throws {
        defer {
            dirty.bookFolderLinks.removeAll()
            dirty.bookAlbumLinks.removeAll()
            dirty.orphanBookRows.removeAll()
            dirty.allBooks = false
        }
        if dirty.allBooks {
            try db.execute(sql: "UPDATE songBook SET bookID = NULL, displayTitle = NULL; DELETE FROM book;")
            for kind in Self.spokenKinds {
                let rowids = try Int64.fetchAll(db, sql: "SELECT songRowid FROM songBook WHERE kind = ?", arguments: [kind])
                try placeBooks(kind: kind, members: Set(rowids))
            }
            return
        }
        func split(_ links: Set<String>) -> [Int: Set<String>] {
            var result: [Int: Set<String>] = [:]
            for link in links {
                let parts = link.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = Int(parts[0]) else { continue }
                result[kind, default: []].insert(parts[1])
            }
            return result
        }
        let folderSeeds = split(dirty.bookFolderLinks)
        let albumSeeds = split(dirty.bookAlbumLinks)
        var orphans: [Int: Set<Int64>] = [:]
        for chunk in LibraryCatalog.chunks(of: Array(dirty.orphanBookRows)) {
            for row in try Row.fetchAll(db, sql: """
                SELECT songRowid, kind FROM songBook WHERE songRowid IN (\(LibraryCatalog.placeholders(chunk.count)))
                """, arguments: StatementArguments(Array(chunk))) {
                orphans[row[1], default: []].insert(row[0])
            }
        }
        for kind in Self.spokenKinds {
            var members = orphans[kind] ?? []
            var seenFolders = Set<String>()
            var seenAlbums = Set<String>()
            var folderFrontier = folderSeeds[kind] ?? []
            var albumFrontier = albumSeeds[kind] ?? []
            while !folderFrontier.isEmpty || !albumFrontier.isEmpty {
                seenFolders.formUnion(folderFrontier)
                seenAlbums.formUnion(albumFrontier)
                var nextFolders = Set<String>()
                var nextAlbums = Set<String>()
                for (column, links) in [("folderLink", Array(folderFrontier)), ("albumLink", Array(albumFrontier))] {
                    for chunk in LibraryCatalog.chunks(of: links) {
                        var arguments: StatementArguments = [kind]
                        arguments += StatementArguments(Array(chunk))
                        for row in try Row.fetchAll(db, sql: """
                            SELECT songRowid, folderLink, albumLink FROM songBook
                            WHERE kind = ? AND \(column) IN (\(LibraryCatalog.placeholders(chunk.count)))
                            """, arguments: arguments) {
                            members.insert(row[0])
                            if let folder: String = row[1], !seenFolders.contains(folder) { nextFolders.insert(folder) }
                            if let album: String = row[2], !seenAlbums.contains(album) { nextAlbums.insert(album) }
                        }
                    }
                }
                folderFrontier = nextFolders
                albumFrontier = nextAlbums
            }
            if !members.isEmpty { try placeBooks(kind: kind, members: members) }
        }
        try db.execute(sql: """
            DELETE FROM book WHERE NOT EXISTS (SELECT 1 FROM songBook b WHERE b.bookID = book.id AND b.kind = book.kind)
            """)
    }

    /// 对一组同类别条目(闭包)重跑归书:可见的按库内顺序交给参照实现,停用源里的清空。
    private mutating func placeBooks(kind: Int, members: Set<Int64>) throws {
        var rows: [Row] = []
        for chunk in LibraryCatalog.chunks(of: Array(members)) {
            try db.execute(sql: """
                UPDATE songBook SET bookID = NULL, displayTitle = NULL
                WHERE songRowid IN (\(LibraryCatalog.placeholders(chunk.count)))
                """, arguments: StatementArguments(Array(chunk)))
            rows += try Row.fetchAll(db, sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns), song.orderKey \(LibraryCatalogSongCodec.selectFrom)
                WHERE song.rowid IN (\(LibraryCatalog.placeholders(chunk.count))) AND source.enabled = 1
                """, arguments: StatementArguments(Array(chunk)))
        }
        guard !rows.isEmpty else { return }
        let orderColumn = LibraryCatalogSongCodec.Column.extra + 1
        var decoded: [(orderKey: Int64, rowid: Int64, song: Song)] = []
        decoded.reserveCapacity(rows.count)
        for row in rows {
            decoded.append((row[orderColumn], row[LibraryCatalogSongCodec.Column.rowid], try LibraryCatalogSongCodec.decode(row)))
        }
        decoded.sort { $0.orderKey != $1.orderKey ? $0.orderKey < $1.orderKey : $0.song.id < $1.song.id }
        let placement = SpokenWordBookGrouping.bookPlacement(for: decoded.map { SpokenWordBookItem(song: $0.song) })
        let update = try db.cachedStatement(sql: "UPDATE songBook SET bookID = ?, displayTitle = ? WHERE songRowid = ?")
        for entry in decoded {
            guard let bookID = placement.bookIDs[entry.song.id] else { continue }
            try update.execute(arguments: [bookID, placement.displayTitles[entry.song.id], entry.rowid])
        }
        let insertBook = try db.cachedStatement(sql: "INSERT OR REPLACE INTO book (id, kind, title) VALUES (?, ?, ?)")
        for bookID in Set(placement.bookIDs.values) {
            try insertBook.execute(arguments: [bookID, kind, placement.groupTitles[bookID]])
        }
    }

    /// 文件夹的直接歌曲数;没有歌、也没有子文件夹的删掉(逐级向上)。
    private mutating func recountFolders() throws {
        var pending = dirty.folders
        while let folder = pending.popFirst() {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM song WHERE folderKey = ?", arguments: [folder]) ?? 0
            // 带上源键:(源, 上一级, 名字) 的唯一索引才用得上,否则每个脏文件夹都要扫整张文件夹表。
            let children = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM folder WHERE sourceKey = (SELECT sourceKey FROM folder WHERE key = ?) AND parentKey = ?
                """, arguments: [folder, folder]) ?? 0
            if count == 0, children == 0 {
                let parent = try Int64.fetchOne(db, sql: "SELECT parentKey FROM folder WHERE key = ?", arguments: [folder])
                try db.execute(sql: "DELETE FROM folder WHERE key = ?", arguments: [folder])
                folderCache.removeAll()
                if let parent, parent != 0 { pending.insert(parent) }
            } else {
                try db.execute(sql: "UPDATE folder SET songCount = ? WHERE key = ?", arguments: [count, folder])
            }
        }
    }
}
