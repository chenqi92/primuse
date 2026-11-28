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

    /// 打开了跨文件夹、跨源的合并开关:专辑艺人推断的范围扩到整个标题。
    var mergesAcrossFolders: Bool {
        artistNames.mergesCollaborativeAlbums || artistNames.mergesSameNamedAlbums
    }
}

/// 专辑艺人推断所看的「目录」:扫描索引给文件夹的源用存下的父文件夹,其余用所在文件夹的键
/// (同一个源里不同目录 ↔ 不同键,与按路径取目录的判定一致)。
enum GroupingDirectory: Hashable {
    case folder(Int64)
    case parent(String)

    var text: String {
        switch self {
        case .folder(let key): return "f\(key)"
        case .parent(let value): return value
        }
    }

    init?(usesFolderParents: Bool, folderKey: Int64?, inferenceDirectory: String?) {
        if usesFolderParents {
            guard let inferenceDirectory else { return nil }
            self = .parent(inferenceDirectory)
        } else {
            guard let folderKey else { return nil }
            self = .folder(folderKey)
        }
    }
}

/// 一行改动所在的推断范围(源、目录、标题)。值表示这一行可能在服务器专辑里。
struct GroupingScopeSeed: Hashable {
    let sourceKey: Int64
    let directory: GroupingDirectory?
    let titleHash: Int64
}

struct GroupingSourceTitle: Hashable {
    let sourceKey: Int64
    let titleHash: Int64
}

struct GroupingStatKey: Hashable {
    let artistRef: Int64
    let sourceKey: Int64
    let kind: Int
}

/// 增量维护时收集的脏范围与计数增量。全部与改动的行数同阶。
struct GroupingDirtySet {
    var scopeSeeds: [GroupingScopeSeed: Bool] = [:]
    /// 整个(源, 标题)重新推断:目录权威翻转、换父文件夹表。
    var sourceTitles: Set<GroupingSourceTitle> = []
    var albums: Set<Int64> = []
    var artists: Set<Int64> = []
    /// 艺人歌曲数的增量(按名字的署名行,一个名字一行)。
    var artistDeltas: [Int64: Int] = [:]
    /// 按查找口径的艺人 × 源 × 类别计数增量。
    var lookupDeltas: [GroupingStatKey: Int] = [:]
    /// 文件夹直接歌曲数的增量。
    var folderDeltas: [Int64: Int] = [:]
    /// 要重新判目录权威的源。
    var sources: Set<Int64> = []
    /// 有声书归书闭包的起点:(类别, 文件夹键) 与 (类别, 专辑键)。
    var bookFolderLinks: Set<String> = []
    var bookAlbumLinks: Set<String> = []
    /// 停用/启用源、换输入时整个书架重来。
    var allBooks = false
    var orphanBookRows: Set<Int64> = []
    var books: Bool { allBooks || !bookFolderLinks.isEmpty || !bookAlbumLinks.isEmpty || !orphanBookRows.isEmpty }
}

/// 一次写入读、写了多少行(维护代码自己数的)。规模测试与「工作量与改动同阶」的测试用。
public struct LibraryCatalogWriteWork: Sendable, Equatable {
    public var rowsRead = 0
    public var rowsWritten = 0
    /// SQLite 执行的虚拟机指令数(以千计;只在 `LibraryCatalog.measuresWriteWork` 打开时数)。
    /// 任何整表扫描都会让它随曲库变大,不论维护代码读回了几行。
    public var kiloInstructions = 0

    public init() {}
}

/// 整数引用的缓存:艺人 id、流派名、文件夹路径 → 键。导入时跨批复用;条目数有上限,
/// 超出就清空(内存与曲库大小无关)。只在同一个写事务序列里用,事务回滚后整个丢掉。
final class CatalogRefCache {
    struct FolderPath: Hashable {
        let sourceKey: Int64
        let path: String
    }

    struct GenreName: Hashable {
        let name: String
        let id: String
    }

    static let limit = 65_536
    private var artistRefs: [String: Int64] = [:]
    private var genreRefs: [GenreName: Int64] = [:]
    private var folders: [FolderPath: Int64] = [:]
    /// 上一次解析的目录(导入时同一目录的歌挨着)。与 `folders` 一起清。
    private var lastFolder: (sourceKey: Int64, path: String, key: Int64)?
    private var albumKeys: [String: Int64] = [:]

    func artistRef(_ id: String, in db: Database) throws -> Int64 {
        if let ref = artistRefs[id] { return ref }
        let stored = LibraryCatalogDerivedFields.columnText(id)
        let ref: Int64
        if let existing = try Int64.fetchOne(
            db.cachedStatement(sql: "SELECT ref FROM artistRef WHERE id = ?"), arguments: [stored]
        ) {
            ref = existing
        } else {
            try db.cachedStatement(sql: "INSERT INTO artistRef (id) VALUES (?)").execute(arguments: [stored])
            ref = db.lastInsertedRowID
        }
        if artistRefs.count >= Self.limit { artistRefs.removeAll(keepingCapacity: true) }
        artistRefs[id] = ref
        return ref
    }

    func genreRef(name: String, id: String, in db: Database) throws -> Int64 {
        let key = GenreName(name: name, id: id)
        if let ref = genreRefs[key] { return ref }
        let storedName = LibraryCatalogDerivedFields.columnText(name)
        let storedID = LibraryCatalogDerivedFields.columnText(id)
        let ref: Int64
        if let existing = try Int64.fetchOne(
            db.cachedStatement(sql: "SELECT ref FROM genreName WHERE name = ? AND genreID = ?"),
            arguments: [storedName, storedID]
        ) {
            ref = existing
        } else {
            try db.cachedStatement(sql: "INSERT INTO genreName (name, genreID) VALUES (?, ?)")
                .execute(arguments: [storedName, storedID])
            ref = db.lastInsertedRowID
        }
        if genreRefs.count >= Self.limit { genreRefs.removeAll(keepingCapacity: true) }
        genreRefs[key] = ref
        return ref
    }

    /// 目录的文件夹行(连同各级上级),返回它的键。从最深的已缓存上级往下补。
    ///
    /// 导入按库内顺序写,同一目录的歌挨着:先比上一首的目录。没缓存时只往上走到第一个已缓存的
    /// 上级,只给其下没缓存的几级算名字;刚插入的文件夹下面不可能有子文件夹(键自增、不复用),
    /// 不用先查。插入的行与顺序和逐级先查后插完全一样。
    func folderKey(sourceKey: Int64, path: String, in db: Database) throws -> Int64 {
        if let last = lastFolder, last.sourceKey == sourceKey, last.path == path { return last.key }
        let key = try resolveFolderKey(sourceKey: sourceKey, path: path, in: db)
        lastFolder = (sourceKey, path, key)
        return key
    }

    private func resolveFolderKey(sourceKey: Int64, path: String, in db: Database) throws -> Int64 {
        if let key = folders[FolderPath(sourceKey: sourceKey, path: path)] { return key }
        // 从这一级往上收集没缓存的各级(深到浅),停在第一个已缓存的上级。
        var uncached: [String] = [path]
        var parent: Int64 = 0
        while let up = GroupingMaintenance.parentFolder(of: uncached[uncached.count - 1]) {
            if let key = folders[FolderPath(sourceKey: sourceKey, path: up)] {
                parent = key
                break
            }
            uncached.append(up)
        }
        let select = try db.cachedStatement(sql: """
            SELECT key FROM folder WHERE sourceKey = ? AND parentKey = ? AND name = ? AND oddPath = ?
            """)
        let insert = try db.cachedStatement(sql: "INSERT INTO folder (sourceKey, parentKey, name, oddPath) VALUES (?, ?, ?, ?)")
        var parentIsNew = false
        for value in uncached.reversed() {
            let component = GroupingMaintenance.folderComponent(of: value)
            if !parentIsNew,
               let key = try Int64.fetchOne(select, arguments: [sourceKey, parent, component.name, component.oddPath]) {
                parent = key
            } else {
                try insert.execute(arguments: [sourceKey, parent, component.name, component.oddPath])
                parent = db.lastInsertedRowID
                parentIsNew = true
            }
            if folders.count >= Self.limit { folders.removeAll(keepingCapacity: true) }
            folders[FolderPath(sourceKey: sourceKey, path: value)] = parent
        }
        return parent
    }

    func forgetFolders() {
        folders.removeAll(keepingCapacity: true)
        lastFolder = nil
    }

    func albumKey(id: String) -> Int64? { albumKeys[id] }

    func remember(albumKey: Int64, id: String) {
        if albumKeys.count >= Self.limit { albumKeys.removeAll(keepingCapacity: true) }
        albumKeys[id] = albumKey
    }

    func forgetAlbums() { albumKeys.removeAll(keepingCapacity: true) }
}

/// 写事务内的分组维护。逐行派生(类别、艺人、流派、文件夹、书的连接键)随行写;依赖其他行的
/// (专辑艺人推断、专辑、艺人、目录权威、有声书)只对脏范围重算,工作量与改动同阶:
/// - 推断按(源、目录、标题)范围重跑,打开合并开关时按标题;
/// - 专辑按专辑键从它自己的歌聚合;
/// - 艺人按键:歌曲数用增量,名字、首次出现、缩略图各一次带索引的查询,专辑数数专辑表;
/// - 文件夹计数与按源的艺人统计用增量;目录权威用两次索引探测。
struct GroupingMaintenance {
    let db: Database
    let configuration: LibraryGroupingConfiguration
    let refs: CatalogRefCache
    var dirty = GroupingDirtySet()
    var work = LibraryCatalogWriteWork()
    /// 导入与整库重建按阶段流式处理,不攒脏范围与增量。
    var tracksDirty = true
    private var sourceCache: [Int64: SourceInfo] = [:]
    /// 发行类型标签 → 认出的类别(专辑的发行类别按它算;标签的写法不多,正则只跑一次)。
    private var releaseTypeFlags: [String: AlbumReleaseCategoryRule.Flags] = [:]

    /// 一首歌的发行类型标签认出的类别(`AlbumReleaseCategoryRule.explicitFlags`,记住各个写法的结果)。
    mutating func releaseFlags(releaseType: String?) -> AlbumReleaseCategoryRule.Flags {
        guard let releaseType, !releaseType.isEmpty else { return [] }
        if let known = releaseTypeFlags[releaseType] { return known }
        let flags = AlbumReleaseCategoryRule.explicitFlags(releaseType: releaseType)
        // 写坏了的逐首标签不能让这份缓存跟着歌数长。
        if releaseTypeFlags.count >= 512 { releaseTypeFlags.removeAll(keepingCapacity: true) }
        releaseTypeFlags[releaseType] = flags
        return flags
    }

    struct SourceInfo {
        let id: String
        let usesFolderParents: Bool
        let hasDirectoryAuthority: Bool
    }

    init(db: Database, configuration: LibraryGroupingConfiguration, refs: CatalogRefCache = CatalogRefCache()) {
        self.db = db
        self.configuration = configuration
        self.refs = refs
    }

    static let spokenKinds = [LibraryCatalogContentKind.spokenWord.rawValue, LibraryCatalogContentKind.podcast.rawValue]

    // MARK: - Per-row values (pure)

    /// 一行的逐行派生,纯函数(可以多核并行算)。
    struct RowValues: @unchecked Sendable {
        var kind: Int
        /// 按名字的艺人 id,一个名字一个(下标即署名次序)。
        var artistIDs: [String]
        var lookupIDs: [String]
        var genres: [(id: String, name: String)]
        var folderPath: String
        var bookLinks: (folder: String?, album: String?)?
        var hasArtistArtwork: Bool
    }

    /// 艺人解析只看这首歌的艺人字段:同样的字段整库里反复出现,解析一次记下。
    struct ArtistResolution: Sendable {
        let nameIDs: [String]
        let lookupIDs: [String]
    }

    struct GenreInput: Hashable {
        let genre: String
        let slashConvention: Bool
    }

    /// 跨批复用的解析结果(导入用)。条目数有上限。
    final class RowValueMemo: @unchecked Sendable {
        var artists: [LibraryGroupingReference.ArtistResolutionFields: ArtistResolution] = [:]
        var genres: [GenreInput: [(id: String, name: String)]] = [:]
        static let limit = 65_536
    }

    static func artistResolution(for song: Song, configuration: LibraryGroupingConfiguration) -> ArtistResolution {
        ArtistResolution(
            nameIDs: LibraryGroupingReference.resolvedArtistNames(
                for: song, configuration: configuration.artistNames, unknownArtist: configuration.unknownArtist
            ).map { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) },
            lookupIDs: LibraryGroupingReference.resolvedArtistIDs(
                for: song, configuration: configuration.artistNames, unknownArtist: configuration.unknownArtist
            )
        )
    }

    static func genreValues(_ input: GenreInput, separators: GenreSeparatorOptions) -> [(id: String, name: String)] {
        var genres: [(id: String, name: String)] = []
        for name in GenreTagValues.names(in: input.genre, alsoSplitting: separators, slashConvention: input.slashConvention) {
            let id = LibraryGenreIndexBuilder.normalizedID(for: name)
            if !id.isEmpty { genres.append((id, name)) }
        }
        return genres
    }

    static func contentKind(of song: Song, configuration: LibraryGroupingConfiguration) -> Int {
        let classification = configuration.classification
        if classification.collectionOnlySongIDs.contains(song.id) {
            return LibraryCatalogContentKind.collectionOnly.rawValue
        }
        var verdicts: [String: ListeningContentKind] = [:]
        switch classification.kind(
            songID: song.id, sourceID: song.sourceID, filePath: song.filePath, genre: song.genre,
            serverLibraryID: song.serverLibraryID, genreVerdicts: &verdicts
        ) {
        case .music: return LibraryCatalogContentKind.music.rawValue
        case .spokenWord: return LibraryCatalogContentKind.spokenWord.rawValue
        case .podcast: return LibraryCatalogContentKind.podcast.rawValue
        case .ambient: return LibraryCatalogContentKind.ambient.rawValue
        }
    }

    static func rowValues(
        for song: Song,
        configuration: LibraryGroupingConfiguration,
        artists: ArtistResolution,
        genres: [(id: String, name: String)]
    ) -> RowValues {
        let kind = contentKind(of: song, configuration: configuration)
        return RowValues(
            kind: kind,
            artistIDs: artists.nameIDs,
            lookupIDs: artists.lookupIDs,
            genres: genres,
            folderPath: AlbumArtistInferencePolicy.directory(ofPath: song.filePath),
            bookLinks: spokenKinds.contains(kind)
                ? SpokenWordBookGroupingRules.linkKeys(of: SpokenWordBookItem(song: song)) : nil,
            hasArtistArtwork: song.artistArtworkFileName != nil
        )
    }

    static func rowValues(for song: Song, configuration: LibraryGroupingConfiguration) -> RowValues {
        rowValues(
            for: song, configuration: configuration,
            artists: artistResolution(for: song, configuration: configuration),
            genres: song.genre.map {
                genreValues(.init(genre: $0, slashConvention: GenreSlashConvention.applies(to: song.fileFormat)),
                            separators: configuration.genreSeparators)
            } ?? []
        )
    }

    /// 一批歌的逐行派生:先串行挑出没见过的艺人字段与流派值,只解析这些(多核),再多核算每行。
    static func rowValues(
        for songs: [Song],
        configuration: LibraryGroupingConfiguration,
        memo: RowValueMemo = RowValueMemo()
    ) -> [RowValues] {
        typealias Fields = LibraryGroupingReference.ArtistResolutionFields
        var fields: [Fields] = []
        fields.reserveCapacity(songs.count)
        var missingArtists: [Fields] = []
        var missingArtistSongs: [Int] = []
        var pendingArtists = Set<Fields>()
        var genreInputs: [GenreInput?] = []
        genreInputs.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            let key = Fields(song)
            fields.append(key)
            if memo.artists[key] == nil, pendingArtists.insert(key).inserted {
                missingArtists.append(key)
                missingArtistSongs.append(index)
            }
            let genre = song.genre.map { GenreInput(genre: $0, slashConvention: GenreSlashConvention.applies(to: song.fileFormat)) }
            genreInputs.append(genre)
            if let genre, memo.genres[genre] == nil {
                memo.genres[genre] = genreValues(genre, separators: configuration.genreSeparators)
            }
        }
        if !missingArtists.isEmpty {
            let resolved = ParallelSlots<ArtistResolution>.map(count: missingArtists.count, minimumSlice: 16) { range, out in
                for index in range {
                    out.set(index, artistResolution(for: songs[missingArtistSongs[index]], configuration: configuration))
                }
            }
            if memo.artists.count + resolved.count > RowValueMemo.limit { memo.artists.removeAll(keepingCapacity: true) }
            for (key, value) in zip(missingArtists, resolved) { memo.artists[key] = value }
        }
        let artists = memo.artists
        let genres = memo.genres
        if memo.genres.count > RowValueMemo.limit { memo.genres.removeAll(keepingCapacity: true) }
        return ParallelSlots<RowValues>.map(count: songs.count) { range, out in
            for index in range {
                let resolution = artists[fields[index]] ?? artistResolution(for: songs[index], configuration: configuration)
                out.set(index, rowValues(
                    for: songs[index], configuration: configuration, artists: resolution,
                    genres: genreInputs[index].flatMap { genres[$0] } ?? []
                ))
            }
        }
    }

    // MARK: - Sources

    mutating func sourceInfo(_ key: Int64) throws -> SourceInfo {
        if let info = sourceCache[key] { return info }
        guard let row = try Row.fetchOne(
            db, sql: "SELECT id, usesFolderParents, hasDirectoryAuthority FROM source WHERE key = ?", arguments: [key]
        ) else { throw LibraryCatalogError.corruptRow }
        let info = SourceInfo(id: row[0], usesFolderParents: (row[1] as Int) != 0, hasDirectoryAuthority: (row[2] as Int) != 0)
        sourceCache[key] = info
        return info
    }

    mutating func forgetSources() { sourceCache.removeAll() }

    func directory(of fields: LibraryCatalogSongCodec.GroupingFields, source: SourceInfo) -> String? {
        GroupingDirectory(
            usesFolderParents: source.usesFolderParents, folderKey: fields.folderKey,
            inferenceDirectory: fields.inferenceDirectory
        )?.text
    }

    // MARK: - Before a row changes

    /// 记下这一行改动前所在的范围与要撤销的计数(旧标题范围、旧专辑、旧艺人、旧文件夹、旧书)。
    mutating func noteExisting(rowid: Int64) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT s.sourceKey, s.kind, s.folderKey, s.inferenceDirectory, s.titleHash, s.flags, s.effectiveAlbumRef,
                       src.usesFolderParents, b.songRowid, b.folderLink, b.albumLink
                FROM song s JOIN source src ON src.key = s.sourceKey
                LEFT JOIN songBook b ON b.songRowid = s.rowid WHERE s.rowid = ?
                """,
            arguments: [rowid]
        ) else { return }
        work.rowsRead += 1
        let sourceKey: Int64 = row[0]
        let kind: Int = row[1]
        let folderKey: Int64? = row[2]
        if let titleHash: Int64 = row[4] {
            let directory = GroupingDirectory(
                usesFolderParents: (row[7] as Int) != 0, folderKey: folderKey, inferenceDirectory: row[3]
            )
            let flags: Int = row[5]
            seedScope(sourceKey: sourceKey, directory: directory, titleHash: titleHash,
                      mayBeInServerAlbum: flags & LibraryCatalogSongFlags.serverCatalogAlbum != 0)
        }
        if let album: Int64 = row[6] { dirty.albums.insert(album) }
        if let folderKey { dirty.folderDeltas[folderKey, default: 0] -= 1 }
        dirty.sources.insert(sourceKey)
        if (row[8] as Int64?) != nil {
            let folderLink: String? = row[9]
            let albumLink: String? = row[10]
            if let link = folderLink { dirty.bookFolderLinks.insert("\(kind)\u{1}\(link)") }
            if let link = albumLink { dirty.bookAlbumLinks.insert("\(kind)\u{1}\(link)") }
            if folderLink == nil, albumLink == nil {
                // 独立成书的条目没有连接键:它所在的书只有它自己,删掉或改动后那本书要清掉。
                dirty.orphanBookRows.insert(rowid)
            }
        }
        for ref in try Int64.fetchAll(
            db.cachedStatement(sql: "SELECT artistRef FROM songArtist WHERE songRowid = ?"), arguments: [rowid]
        ) {
            work.rowsRead += 1
            dirty.artistDeltas[ref, default: 0] -= 1
            dirty.artists.insert(ref)
        }
        for ref in try Int64.fetchAll(
            db.cachedStatement(sql: "SELECT artistRef FROM songArtistLookup WHERE songRowid = ?"), arguments: [rowid]
        ) {
            work.rowsRead += 1
            dirty.lookupDeltas[GroupingStatKey(artistRef: ref, sourceKey: sourceKey, kind: kind), default: 0] -= 1
        }
    }

    mutating func removeDerivedRows(rowid: Int64) throws {
        for table in ["songArtist", "songArtistLookup", "songGenre", "songBook"] {
            try db.cachedStatement(sql: "DELETE FROM \(table) WHERE songRowid = ?").execute(arguments: [rowid])
            work.rowsWritten += db.changesCount
        }
    }

    mutating func seedScope(sourceKey: Int64, directory: GroupingDirectory?, titleHash: Int64, mayBeInServerAlbum: Bool) {
        let seed = GroupingScopeSeed(sourceKey: sourceKey, directory: directory, titleHash: titleHash)
        dirty.scopeSeeds[seed] = (dirty.scopeSeeds[seed] ?? false) || mayBeInServerAlbum
    }

    // MARK: - Per-row derivation

    /// 写入一行的派生表行:艺人(按名字与按查找 id)、流派、有声书连接键;并记下新状态的范围与增量。
    /// 类别与文件夹键已随歌曲行写好。
    mutating func writeRow(
        rowid: Int64,
        sourceKey: Int64,
        kind: Int,
        folderKey: Int64,
        directory: GroupingDirectory?,
        titleHash: Int64?,
        mayBeInServerAlbum: Bool,
        values: RowValues
    ) throws {
        let insertArtist = try db.cachedStatement(sql: """
            INSERT INTO songArtist (songRowid, ordinal, artistRef, artwork) VALUES (?, ?, ?, ?)
            """)
        let artwork: Int64 = values.hasArtistArtwork ? 1 : 0
        for (ordinal, id) in values.artistIDs.enumerated() {
            let ref = try refs.artistRef(id, in: db)
            CatalogStatement.bind([.int(rowid), .int(Int64(ordinal)), .int(ref), .int(artwork)], to: insertArtist)
            try CatalogStatement.execute(insertArtist, in: db)
            if tracksDirty {
                dirty.artistDeltas[ref, default: 0] += 1
                dirty.artists.insert(ref)
            }
        }
        let insertLookup = try db.cachedStatement(sql: "INSERT OR IGNORE INTO songArtistLookup (songRowid, artistRef) VALUES (?, ?)")
        for id in values.lookupIDs {
            let ref = try refs.artistRef(id, in: db)
            CatalogStatement.bind([.int(rowid), .int(ref)], to: insertLookup)
            try CatalogStatement.execute(insertLookup, in: db)
            if tracksDirty, db.changesCount > 0 {
                dirty.lookupDeltas[GroupingStatKey(artistRef: ref, sourceKey: sourceKey, kind: kind), default: 0] += 1
            }
        }
        let insertGenre = try db.cachedStatement(sql: "INSERT INTO songGenre (songRowid, ordinal, genreRef) VALUES (?, ?, ?)")
        for (ordinal, genre) in values.genres.enumerated() {
            let ref = try refs.genreRef(name: genre.name, id: genre.id, in: db)
            CatalogStatement.bind([.int(rowid), .int(Int64(ordinal)), .int(ref)], to: insertGenre)
            try CatalogStatement.execute(insertGenre, in: db)
        }
        if let links = values.bookLinks {
            let insertBook = try db.cachedStatement(sql: """
                INSERT INTO songBook (songRowid, kind, folderLink, albumLink) VALUES (?, ?, ?, ?)
                """)
            CatalogStatement.bind(
                [.int(rowid), .int(Int64(kind)), .optionalText(links.folder.map(LibraryCatalogDerivedFields.columnText)),
                 .optionalText(links.album.map(LibraryCatalogDerivedFields.columnText))],
                to: insertBook
            )
            try CatalogStatement.execute(insertBook, in: db)
            if tracksDirty {
                if let link = links.folder { dirty.bookFolderLinks.insert("\(kind)\u{1}\(LibraryCatalogDerivedFields.columnText(link))") }
                if let link = links.album { dirty.bookAlbumLinks.insert("\(kind)\u{1}\(LibraryCatalogDerivedFields.columnText(link))") }
                if links.folder == nil, links.album == nil { dirty.orphanBookRows.insert(rowid) }
            }
        }
        work.rowsWritten += values.artistIDs.count + values.lookupIDs.count + values.genres.count
            + (values.bookLinks == nil ? 0 : 1)
        guard tracksDirty else { return }
        dirty.folderDeltas[folderKey, default: 0] += 1
        dirty.sources.insert(sourceKey)
        if let titleHash {
            seedScope(sourceKey: sourceKey, directory: directory, titleHash: titleHash, mayBeInServerAlbum: mayBeInServerAlbum)
        }
    }

    // MARK: - Folders

    /// 目录的文件夹:按「上一级 + 名字」逐级存,不存整条路径。路径写法与上一级加名字拼不回来
    /// (比如 "a//b")时原样记在 `oddPath`,保证不同的目录写法不会并成一个文件夹。
    struct FolderComponent: Hashable {
        let name: String
        let oddPath: String
    }

    /// 从根到这一级的每一级目录(路径与它的组成)。
    static func folderLevels(of path: String) -> [(path: String, component: FolderComponent)] {
        var chain: [String] = []
        var current: String? = path
        while let value = current {
            chain.append(value)
            current = parentFolder(of: value)
        }
        return chain.reversed().map { ($0, folderComponent(of: $0)) }
    }

    /// 一级目录在文件夹表里的组成:名字,以及按上级拼不回原样时的原路径。
    static func folderComponent(of value: String) -> FolderComponent {
        let name = folderName(of: value)
        let rebuilt = parentFolder(of: value).map { joinFolder($0, name) } ?? name
        return FolderComponent(name: name, oddPath: rebuilt == value ? "" : value)
    }

    static func folderChain(of path: String) -> [FolderComponent] {
        folderLevels(of: path).map(\.component)
    }

    static func joinFolder(_ parent: String, _ name: String) -> String {
        if parent.isEmpty { return name }
        if parent == "/" { return "/" + name }
        return parent + "/" + name
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

    func folderKey(sourceKey: Int64, path: String) throws -> Int64 {
        try refs.folderKey(sourceKey: sourceKey, path: path, in: db)
    }

    /// 把直接歌曲数的增量记进文件夹表;没有歌、也没有子文件夹的删掉(逐级向上)。
    private mutating func applyFolderDeltas() throws {
        var pending = Set<Int64>()
        let update = try db.cachedStatement(sql: "UPDATE folder SET songCount = songCount + ? WHERE key = ? RETURNING songCount")
        for (key, delta) in dirty.folderDeltas where delta != 0 {
            let count = try Int.fetchOne(update, arguments: [delta, key])
            work.rowsWritten += 1
            if count == 0 { pending.insert(key) }
        }
        while let folder = pending.popFirst() {
            guard let row = try Row.fetchOne(
                db.cachedStatement(sql: "SELECT songCount, parentKey, sourceKey FROM folder WHERE key = ?"), arguments: [folder]
            ) else { continue }
            work.rowsRead += 1
            guard (row[0] as Int) == 0 else { continue }
            let parent: Int64 = row[1]
            // 带上源键:(源, 上一级, 名字) 的唯一索引才用得上。
            let hasChild = try Bool.fetchOne(
                db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM folder WHERE sourceKey = ? AND parentKey = ?)"),
                arguments: [row[2] as Int64, folder]
            ) ?? false
            guard !hasChild else { continue }
            try db.cachedStatement(sql: "DELETE FROM folder WHERE key = ?").execute(arguments: [folder])
            work.rowsWritten += 1
            refs.forgetFolders()
            if parent != 0 { pending.insert(parent) }
        }
    }

    /// 整库:全部文件夹的直接歌曲数,删掉没有歌也没有子文件夹的。
    func recountAllFolders() throws {
        try db.execute(sql: """
            UPDATE folder SET songCount = (SELECT count(*) FROM song WHERE song.folderKey = folder.key)
            """)
        while true {
            try db.execute(sql: """
                DELETE FROM folder WHERE songCount = 0
                AND NOT EXISTS (SELECT 1 FROM folder child WHERE child.sourceKey = folder.sourceKey AND child.parentKey = folder.key)
                """)
            if db.changesCount == 0 { break }
        }
        refs.forgetFolders()
    }

    // MARK: - Directory authority

    /// 「源里至少有两个不同目录才有目录权威」:两次索引探测,与源的大小无关。
    static func hasDirectoryAuthority(sourceKey: Int64, usesFolderParents: Bool, in db: Database) throws -> Bool {
        if usesFolderParents {
            guard let first = try String.fetchOne(db, sql: """
                SELECT min(inferenceDirectory) FROM song WHERE sourceKey = ? AND inferenceDirectory IS NOT NULL
                """, arguments: [sourceKey]) else { return false }
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM song WHERE sourceKey = ? AND inferenceDirectory > ?)
                """, arguments: [sourceKey, first]) ?? false
        }
        // 文件夹的直接歌曲数 > 0 ⇔ 有歌以它为目录。
        return (try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT 1 FROM folder WHERE sourceKey = ? AND songCount > 0 LIMIT 2)
            """, arguments: [sourceKey]) ?? 0) >= 2
    }

    /// 权威翻转时这个源的所有标题都要重推断。
    private mutating func refreshDirectoryAuthority() throws {
        for sourceKey in dirty.sources {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT hasDirectoryAuthority, usesFolderParents FROM source WHERE key = ?
                """, arguments: [sourceKey]) else { continue }
            let current = (row[0] as Int) != 0
            let next = try Self.hasDirectoryAuthority(sourceKey: sourceKey, usesFolderParents: (row[1] as Int) != 0, in: db)
            guard next != current else { continue }
            try db.execute(sql: "UPDATE source SET hasDirectoryAuthority = ? WHERE key = ?", arguments: [next ? 1 : 0, sourceKey])
            sourceCache[sourceKey] = nil
            for titleHash in try Int64.fetchAll(db, sql: """
                SELECT DISTINCT titleHash FROM song WHERE sourceKey = ? AND titleHash IS NOT NULL
                """, arguments: [sourceKey]) {
                dirty.sourceTitles.insert(GroupingSourceTitle(sourceKey: sourceKey, titleHash: titleHash))
            }
        }
    }

    // MARK: - Flush

    mutating func flush() throws {
        typealias Profile = LibraryCatalogImportProfile
        try Profile.measure("flush.folders") { try applyFolderDeltas() }
        try Profile.measure("flush.authority") { try refreshDirectoryAuthority() }
        try Profile.measure("flush.scopes") { try regroupDirtyScopes() }
        try Profile.measure("flush.albums") { try refreshDirtyAlbums() }
        try Profile.measure("flush.artists") { try refreshDirtyArtists() }
        try Profile.measure("flush.artistStats") { try applyLookupDeltas() }
        if dirty.books { try Profile.measure("flush.books") { try rebuildBooks() } }
        dirty = GroupingDirtySet()
    }

    // MARK: - Books

    /// 有声书/播客的归书规则会读同一文件夹、同一专辑的其他条目:从改动的条目出发,沿文件夹键与
    /// 专辑键(`SpokenWordBookGroupingRules.linkKeys`)求闭包,只对闭包里的可见条目重跑参照实现。
    /// 停用/启用源或换输入时整个书架重来。
    /// 整库重建书时每批取的种子行数。
    static let bookRebuildSeedBatch = 2_000

    mutating func rebuildBooks() throws {
        defer {
            dirty.bookFolderLinks.removeAll()
            dirty.bookAlbumLinks.removeAll()
            dirty.orphanBookRows.removeAll()
            dirty.allBooks = false
        }
        if dirty.allBooks {
            try db.execute(sql: "UPDATE songBook SET bookID = NULL, displayTitle = NULL; DELETE FROM book;")
            // 按行号一批批取种子,每批只放它牵连到的连通块:要解码的歌与书的大小同阶,与曲库大小
            // 无关(50 万首一次全解码多占三百来 MiB)。书的归属只取决于所在的连通块(增量维护靠的也是
            // 这一点,差分测试逐步对照),分批放与一次全放结果一样。
            for kind in Self.spokenKinds {
                var placed = Set<Int64>()
                var after: Int64 = 0
                while true {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT songRowid, folderLink, albumLink FROM songBook
                        WHERE kind = ? AND songRowid > ? ORDER BY songRowid LIMIT ?
                        """, arguments: [kind, after, Self.bookRebuildSeedBatch])
                    guard let last = rows.last else { break }
                    after = last[0]
                    var members = Set<Int64>()
                    var folders = Set<String>()
                    var albums = Set<String>()
                    for row in rows {
                        let rowid: Int64 = row[0]
                        guard !placed.contains(rowid) else { continue }
                        members.insert(rowid)
                        if let folder: String = row[1] { folders.insert(folder) }
                        if let album: String = row[2] { albums.insert(album) }
                    }
                    guard !members.isEmpty else { continue }
                    try expandBookClosure(kind: kind, folderSeeds: folders, albumSeeds: albums, into: &members)
                    try placeBooks(kind: kind, members: members)
                    placed.formUnion(members)
                }
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
            try expandBookClosure(kind: kind, folderSeeds: folderSeeds[kind] ?? [], albumSeeds: albumSeeds[kind] ?? [],
                                  into: &members)
            if !members.isEmpty { try placeBooks(kind: kind, members: members) }
        }
        try db.execute(sql: """
            DELETE FROM book WHERE NOT EXISTS (SELECT 1 FROM songBook b WHERE b.bookID = book.id AND b.kind = book.kind)
            """)
    }

    /// 从种子连接键出发,把与它们相连的整个连通块(同一本书可能牵连到的行)收进 `members`。
    private mutating func expandBookClosure(
        kind: Int,
        folderSeeds: Set<String>,
        albumSeeds: Set<String>,
        into members: inout Set<Int64>
    ) throws {
        var seenFolders = Set<String>()
        var seenAlbums = Set<String>()
        var folderFrontier = folderSeeds
        var albumFrontier = albumSeeds
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
                        work.rowsRead += 1
                        members.insert(row[0])
                        if let folder: String = row[1], !seenFolders.contains(folder) { nextFolders.insert(folder) }
                        if let album: String = row[2], !seenAlbums.contains(album) { nextAlbums.insert(album) }
                    }
                }
            }
            folderFrontier = nextFolders
            albumFrontier = nextAlbums
        }
    }

    /// 对一组同类别条目(闭包)重跑归书:可见的按库内顺序交给参照实现,停用源里的清空。
    private mutating func placeBooks(kind: Int, members: Set<Int64>) throws {
        var decoded: [(rowid: Int64, song: Song)] = []
        for chunk in LibraryCatalog.chunks(of: members.sorted()) {
            try db.execute(sql: """
                UPDATE songBook SET bookID = NULL, displayTitle = NULL
                WHERE songRowid IN (\(LibraryCatalog.placeholders(chunk.count)))
                """, arguments: StatementArguments(Array(chunk)))
            let rows = try Row.fetchCursor(db, sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom)
                WHERE song.rowid IN (\(LibraryCatalog.placeholders(chunk.count))) AND source.enabled = 1
                """, arguments: StatementArguments(Array(chunk)))
            while let row = try rows.next() {
                decoded.append((row[LibraryCatalogSongCodec.Column.rowid], try LibraryCatalogSongCodec.decode(row)))
            }
        }
        work.rowsRead += decoded.count
        guard !decoded.isEmpty else { return }
        // 库内顺序就是行号顺序。
        decoded.sort { $0.rowid < $1.rowid }
        let placement = SpokenWordBookGrouping.bookPlacement(for: decoded.map { SpokenWordBookItem(song: $0.song) })
        let update = try db.cachedStatement(sql: "UPDATE songBook SET bookID = ?, displayTitle = ? WHERE songRowid = ?")
        for entry in decoded {
            guard let bookID = placement.bookIDs[entry.song.id] else { continue }
            try update.execute(arguments: [bookID, placement.displayTitles[entry.song.id], entry.rowid])
            work.rowsWritten += 1
        }
        let insertBook = try db.cachedStatement(sql: "INSERT OR REPLACE INTO book (id, kind, title) VALUES (?, ?, ?)")
        for bookID in Set(placement.bookIDs.values) {
            try insertBook.execute(arguments: [bookID, kind, placement.groupTitles[bookID]])
        }
    }
}
