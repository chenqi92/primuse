import Foundation
import PrimuseKit

enum LibraryCatalogReaderError: Error, Equatable {
    /// 目录还没准备好(首次迁移、整库分组、对账还在做),或这台设备上没开目录。
    case unavailable
}

/// 可见范围:已启用源,或连停用源一起(历史记录、播放统计按 id 找歌用)。
enum LibraryCatalogVisibility: Sendable, Equatable {
    case visible
    case includingDisabledSources

    var includesDisabledSources: Bool { self == .includingDisabledSources }
}

/// 一行的身份投影(流式遍历用,不物化整首歌)。
struct LibraryCatalogSongIdentity: Sendable, Hashable {
    let rowid: Int32
    let id: String
    let filePath: String
}

/// 形状 3:资料库页、侧栏、首页要的各类计数,一次读完。
struct LibraryCatalogCounts: Sendable, Equatable {
    var songs = 0
    var visibleSongs = 0
    var music = 0
    var playableMusic = 0
    var spokenWord = 0
    var podcast = 0
    var ambient = 0
    var collectionOnly = 0
    var albums = 0
    var artists = 0
    var genres = 0
    var visibleBySource: [String: Int] = [:]
    var allBySource: [String: Int] = [:]

    var hasPlayableMusic: Bool { playableMusic > 0 }
}

/// 形状 10/11:一本书(有声书或播客节目)。
struct LibraryCatalogBook: Sendable, Equatable, Identifiable {
    let id: String
    let kind: LibraryCatalogContentKind
    let songCount: Int
    /// 库内顺序的第一首(书架封面、续播起点的兜底)。
    let firstSongID: String
    let sourceIDs: Set<String>
}

/// 形状 19:维护谓词。字段为 nil 表示不限。
struct LibraryMaintenancePredicate: Sendable, Equatable {
    var sourceIDs: Set<String>?
    var formats: Set<AudioFormat>?
    var durationRange: ClosedRange<TimeInterval>?
    var bitRateRange: ClosedRange<Int>?
    var fileSizeRange: ClosedRange<Int64>?
    var userEdited: Bool?
    var hasCoverReference: Bool?
    var hasLyricsReference: Bool?
    var hasLyricsText: Bool?
    var kinds: Set<LibraryCatalogContentKind>?

    init(
        sourceIDs: Set<String>? = nil,
        formats: Set<AudioFormat>? = nil,
        durationRange: ClosedRange<TimeInterval>? = nil,
        bitRateRange: ClosedRange<Int>? = nil,
        fileSizeRange: ClosedRange<Int64>? = nil,
        userEdited: Bool? = nil,
        hasCoverReference: Bool? = nil,
        hasLyricsReference: Bool? = nil,
        hasLyricsText: Bool? = nil,
        kinds: Set<LibraryCatalogContentKind>? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.formats = formats
        self.durationRange = durationRange
        self.bitRateRange = bitRateRange
        self.fileSizeRange = fileSizeRange
        self.userEdited = userEdited
        self.hasCoverReference = hasCoverReference
        self.hasLyricsReference = hasLyricsReference
        self.hasLyricsText = hasLyricsText
        self.kinds = kinds
    }

    func matches(_ song: Song) -> Bool {
        if let sourceIDs, !sourceIDs.contains(song.sourceID) { return false }
        if let formats, !formats.contains(song.fileFormat) { return false }
        if let durationRange, !durationRange.contains(song.duration) { return false }
        if let bitRateRange, !bitRateRange.contains(song.bitRate ?? 0) { return false }
        if let fileSizeRange, !fileSizeRange.contains(song.fileSize) { return false }
        if let userEdited, (song.userMetadataEditedAt != nil) != userEdited { return false }
        if let hasCoverReference, (song.coverArtFileName?.isEmpty == false) != hasCoverReference { return false }
        if let hasLyricsReference, (song.lyricsFileName?.isEmpty == false) != hasLyricsReference { return false }
        if let hasLyricsText, (song.lyricsText?.isEmpty == false) != hasLyricsText { return false }
        return true
    }
}

/// 曲库目录的读接口:PLAN §4.3 普查出的 20 种查询形状。全部在主线程外执行。
///
/// 规矩:
/// - 返回 `[Song]` / `[Album]` / `[Artist]` 的接口都带 `limit`,上限 `LibraryScale.maxMaterializedRows`;
/// - 整个范围只给 `LibraryRowList`(行号)或 `LibraryCatalogKeyList`(键),界面用 `LibraryListModel` 按页取;
/// - 需要逐首看的计算走 `visitSongs` / `visitSongIdentities` 流式遍历,内存只占一批。
///
/// 标了「流式」的接口目前在目录公开接口之上逐行过滤(结果有界、内存有界,耗时与范围成正比);
/// 目录补上对应的 SQL 接口后换成直接查询,调用方不用改。
final class LibraryCatalogReader: Sendable {
    private let provider: @Sendable () -> LibraryCatalog?
    /// 全局有界 LRU(PLAN §4.3:约 3000 首)。目录变更时按行号精确失效。
    let rowCache: LibraryRowCache

    init(
        catalog provider: @escaping @Sendable () -> LibraryCatalog?,
        rowCache: LibraryRowCache = LibraryRowCache()
    ) {
        self.provider = provider
        self.rowCache = rowCache
    }

    var isAvailable: Bool { provider() != nil }

    /// 在主线程外对目录执行一段同步查询。
    func read<T: Sendable>(_ body: @escaping @Sendable (LibraryCatalog) throws -> T) async throws -> T {
        guard let catalog = provider() else { throw LibraryCatalogReaderError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body(catalog) })
            }
        }
    }

    private static func cap(_ limit: Int) -> Int {
        min(max(0, limit), LibraryScale.maxMaterializedRows)
    }

    private static func scope(_ visibility: LibraryCatalogVisibility, kinds: Set<LibraryCatalogContentKind>? = nil,
                              sourceID: String? = nil, playableOnly: Bool = false) -> LibrarySongScope {
        LibrarySongScope(kinds: kinds, sourceID: sourceID, includesDisabledSources: visibility.includesDisabledSources,
                         playableOnly: playableOnly)
    }

    // MARK: 1. By id

    /// 按 id 批量取,保持输入顺序;不在的跳过。
    func songs(
        ids: [String],
        visibility: LibraryCatalogVisibility = .includingDisabledSources,
        playableOnly: Bool = false
    ) async throws -> [Song] {
        let scope = Self.scope(visibility, playableOnly: playableOnly)
        return try await read { try $0.songs(ids: ids, scope: scope) }
    }

    func song(id: String, visibility: LibraryCatalogVisibility = .includingDisabledSources) async throws -> Song? {
        try await songs(ids: [id], visibility: visibility).first
    }

    /// 按行号物化(经过行缓存),保持顺序;已删除的位置为 nil。
    func songs(rowids: [Int32]) async throws -> [Song?] {
        let cache = rowCache
        return try await read { try cache.songs(forRowids: rowids, in: $0) }
    }

    func rowids(forIDs ids: [String]) async throws -> [Int32?] {
        try await read { try $0.rowids(forIDs: ids) }
    }

    // MARK: 2. Content kind

    func contentKind(songID: String) async throws -> LibraryCatalogContentKind? {
        try await read { try $0.contentKind(songID: songID) }
    }

    func rowList(kinds: Set<LibraryCatalogContentKind>, visibility: LibraryCatalogVisibility = .visible) async throws -> LibraryRowList {
        let scope = Self.scope(visibility, kinds: kinds)
        return try await read { try $0.rowList(scope) }
    }

    // MARK: 3. Counts

    func counts() async throws -> LibraryCatalogCounts {
        try await read { catalog in
            var counts = LibraryCatalogCounts()
            counts.songs = try catalog.songCount(.everything)
            counts.visibleSongs = try catalog.songCount(.visible)
            counts.music = try catalog.songCount(.visibleMusic)
            counts.playableMusic = try catalog.songCount(LibrarySongScope(kinds: [.music], playableOnly: true))
            counts.spokenWord = try catalog.songCount(LibrarySongScope(kinds: [.spokenWord, .podcast]))
            counts.podcast = try catalog.songCount(LibrarySongScope(kinds: [.podcast]))
            counts.ambient = try catalog.songCount(LibrarySongScope(kinds: [.ambient]))
            counts.collectionOnly = try catalog.songCount(LibrarySongScope(kinds: [.collectionOnly]))
            counts.albums = try catalog.albumKeys(visibleOnly: true).count
            counts.artists = try catalog.artistKeys(visibleOnly: true).count
            counts.genres = try catalog.genres().count
            counts.visibleBySource = try catalog.songCountsBySource(.visible)
            counts.allBySource = try catalog.songCountsBySource(.everything)
            return counts
        }
    }

    func songCount(_ scope: LibrarySongScope) async throws -> Int {
        try await read { try $0.songCount(scope) }
    }

    /// 带 MV 的可见音乐(流式)。
    func musicVideoRowList() async throws -> LibraryRowList {
        try await filteredRowList(.visibleMusic) { $0.hasMusicVideo }
    }

    /// 有声书或播客节目的本数(流式:逐首读归书结果)。
    func bookCount(kind: LibraryCatalogContentKind) async throws -> Int {
        try await bookshelf(kind: kind).count
    }

    // MARK: 4. Songs of a source

    func rowList(sourceID: String, visibility: LibraryCatalogVisibility = .visible, playableOnly: Bool = false) async throws -> LibraryRowList {
        let scope = Self.scope(visibility, sourceID: sourceID, playableOnly: playableOnly)
        return try await read { try $0.rowList(scope) }
    }

    func containsSongs(sourceID: String, visibility: LibraryCatalogVisibility = .includingDisabledSources) async throws -> Bool {
        let scope = Self.scope(visibility, sourceID: sourceID)
        return try await read { try $0.containsSongs(scope) }
    }

    func firstSong(sourceID: String, visibility: LibraryCatalogVisibility = .includingDisabledSources) async throws -> Song? {
        let scope = Self.scope(visibility, sourceID: sourceID)
        return try await read { try $0.firstSong(scope) }
    }

    /// 某源里不在 `excluding` 里的歌,库内顺序,至多 `limit` 首(流式)。
    func songs(sourceID: String, excluding excluded: Set<String>, limit: Int,
               visibility: LibraryCatalogVisibility = .includingDisabledSources) async throws -> [Song] {
        let cap = Self.cap(limit)
        guard cap > 0 else { return [] }
        let scope = Self.scope(visibility, sourceID: sourceID)
        return try await read { catalog in
            var result: [Song] = []
            try catalog.forEachSong(scope) { _, song in
                if !excluded.contains(song.id) { result.append(song) }
                return result.count < cap
            }
            return result
        }
    }

    /// 按调用方给的键(如服务器条目 id、路径的某种规范化)反查歌曲 id,只查 `keys` 里的(流式)。
    func songIDs(sourceID: String, keys: Set<String>, key: @escaping @Sendable (Song) -> String?) async throws -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        return try await read { catalog in
            var result: [String: String] = [:]
            try catalog.forEachSong(.source(sourceID)) { _, song in
                if let value = key(song), keys.contains(value), result[value] == nil { result[value] = song.id }
                return result.count < keys.count
            }
            return result
        }
    }

    /// 流式遍历一个范围的身份投影;`body` 在主线程外按库内顺序调用,返回 false 提前结束。
    func visitSongIdentities(_ scope: LibrarySongScope, _ body: @escaping @Sendable (LibraryCatalogSongIdentity) -> Bool) async throws {
        try await read { catalog in
            try catalog.forEachSongIdentity(scope) { rowid, id, path in
                body(LibraryCatalogSongIdentity(rowid: rowid, id: id, filePath: path))
            }
        }
    }

    /// 流式遍历整首歌(Spotlight、Siri 建议、补全选批、智能歌单这类逐首计算用)。内存只占一批。
    func visitSongs(_ scope: LibrarySongScope, _ body: @escaping @Sendable (Int32, Song) -> Bool) async throws {
        try await read { catalog in try catalog.forEachSong(scope, body) }
    }

    // MARK: 5. Paths inside a source

    func rowList(sourceID: String, directory: String, recursive: Bool) async throws -> LibraryRowList {
        try await read { try $0.rowList(sourceID: sourceID, directory: directory, recursive: recursive) }
    }

    func songID(sourceID: String, filePath: String) async throws -> String? {
        try await read { try $0.songID(sourceID: sourceID, filePath: filePath) }
    }

    /// 同一个文件的所有行(CUE 分轨)。
    func rowList(sourceID: String, filePath: String) async throws -> LibraryRowList {
        try await read { try $0.rowList(sourceID: sourceID, filePath: filePath) }
    }

    func fileStems(sourceID: String, directory: String, limit: Int = LibraryScale.maxMaterializedRows) async throws -> Set<String> {
        try await read { try $0.fileStems(sourceID: sourceID, directory: directory, limit: limit) }
    }

    func rowList(sourceID: String, directory: String, sharing column: LibraryCatalogSidecarColumn, fileName: String) async throws -> LibraryRowList {
        try await read { try $0.rowList(sourceID: sourceID, directory: directory, sharing: column, fileName: fileName) }
    }

    // MARK: 6. Album songs

    func albumSongRowList(albumID: String) async throws -> LibraryRowList {
        try await read { try $0.albumSongRowList(albumID: albumID) }
    }

    func albumSongs(albumID: String, limit: Int = LibraryScale.maxMaterializedRows) async throws -> [Song] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            try catalog.songs(rowids: catalog.albumSongRowList(albumID: albumID).rowids.prefix(cap))
        }
    }

    /// 一组专辑各自的歌曲 id(按碟号、曲号),总数不超过 `limit`。
    func albumSongIDs(albumIDs: [String], limit: Int = LibraryScale.maxMaterializedRows) async throws -> [String: [String]] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            var result: [String: [String]] = [:]
            var remaining = cap
            for albumID in albumIDs where remaining > 0 {
                let rowids = try catalog.albumSongRowList(albumID: albumID).rowids.prefix(remaining)
                let ids = try catalog.songs(rowids: rowids).map(\.id)
                result[albumID] = ids
                remaining -= ids.count
            }
            return result
        }
    }

    func albumHasSongs(albumID: String) async throws -> Bool {
        try await read { try !$0.albumSongRowList(albumID: albumID).isEmpty }
    }

    func preferredArtworkSongID(albumID: String) async throws -> String? {
        try await read { try $0.preferredArtworkSongID(albumID: albumID) }
    }

    // MARK: 7. Artist songs

    func artistSongRowList(artistID: String) async throws -> LibraryRowList {
        try await read { try $0.artistSongRowList(artistID: artistID) }
    }

    /// 按名字(参与者也算)找歌:名字按艺人身份规则折成 id,合并去重,先到的名字在前。
    func artistSongRowList(names: [String]) async throws -> LibraryRowList {
        let artistIDs = Self.artistIDs(forNames: names)
        return try await read { catalog in
            var seen = Set<Int32>()
            var rowids = ContiguousArray<Int32>()
            var revision: Int64 = 0
            for artistID in artistIDs {
                let list = try catalog.artistSongRowList(artistID: artistID)
                revision = max(revision, list.revision)
                for rowid in list.rowids where seen.insert(rowid).inserted { rowids.append(rowid) }
            }
            return LibraryRowList(rowids: rowids, revision: revision)
        }
    }

    static func artistIDs(forNames names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let id = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(name))
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// 艺人歌曲所在的专辑 id,按第一次出现的先后(流式,至多看 `limit` 首)。
    func albumIDs(forArtistID artistID: String, limit: Int = LibraryScale.maxMaterializedRows) async throws -> [String] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            let songs = try catalog.songs(rowids: catalog.artistSongRowList(artistID: artistID).rowids.prefix(cap))
            var seen = Set<String>()
            return songs.compactMap { song in
                guard let albumID = song.albumID, seen.insert(albumID).inserted else { return nil }
                return albumID
            }
        }
    }

    func preferredArtworkSongID(artistID: String) async throws -> String? {
        try await read { try $0.preferredArtworkSongID(artistID: artistID) }
    }

    // MARK: 8. Genres

    func genres() async throws -> [LibraryGenre] {
        try await read { try $0.genres() }
    }

    func topGenres(limit: Int) async throws -> [LibraryGenre] {
        let genres = try await genres()
        return Array(genres.sorted { lhs, rhs in
            lhs.songCount != rhs.songCount ? lhs.songCount > rhs.songCount : lhs.id < rhs.id
        }.prefix(max(0, limit)))
    }

    /// 某流派的可见音乐,库内顺序(走目录的流派表;拆分规则与 `LibraryGenreIndexBuilder` 一致)。
    func genreSongRowList(genreID: String) async throws -> LibraryRowList {
        try await read { try $0.genreSongRowList(genreID: genreID) }
    }

    /// 某流派里歌曲所在的专辑 id,按第一次出现的先后:只物化这个流派的歌。
    func genreAlbumIDs(genreID: String) async throws -> [String] {
        try await read { catalog in
            let rowids = Array(try catalog.genreSongRowList(genreID: genreID).rowids)
            var seen = Set<String>()
            var result: [String] = []
            var start = 0
            while start < rowids.count {
                let end = min(rowids.count, start + LibraryScale.maxMaterializedRows)
                for song in try catalog.songs(rowids: rowids[start..<end]) {
                    if let albumID = song.albumID, seen.insert(albumID).inserted { result.append(albumID) }
                }
                start = end
            }
            return result
        }
    }

    // MARK: 9. Liked albums and artists

    /// 按 id 解析专辑(收藏、喜欢的专辑),保持输入顺序。目录还没有按 id 取专辑的接口,
    /// 这里按键列表分批物化查找,耗时与专辑数成正比。
    func albums(ids: [String], visibleOnly: Bool = true) async throws -> [Album] {
        let wanted = Set(ids.prefix(LibraryScale.maxMaterializedRows))
        guard !wanted.isEmpty else { return [] }
        return try await read { catalog in
            let keys = try catalog.albumKeys(visibleOnly: visibleOnly).keys
            var byID: [String: Album] = [:]
            var start = 0
            while start < keys.count, byID.count < wanted.count {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for album in try catalog.albums(keys: keys[start..<end], visibleCounts: visibleOnly)
                where wanted.contains(album.id) && byID[album.id] == nil {
                    byID[album.id] = album
                }
                start = end
            }
            return ids.compactMap { byID[$0] }
        }
    }

    func artists(ids: [String], visibleOnly: Bool = true) async throws -> [Artist] {
        let wanted = Set(ids.prefix(LibraryScale.maxMaterializedRows))
        guard !wanted.isEmpty else { return [] }
        return try await read { catalog in
            let keys = try catalog.artistKeys(visibleOnly: visibleOnly).keys
            var byID: [String: Artist] = [:]
            var start = 0
            while start < keys.count, byID.count < wanted.count {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for artist in try catalog.artists(keys: keys[start..<end], visibleCounts: visibleOnly)
                where wanted.contains(artist.id) && byID[artist.id] == nil {
                    byID[artist.id] = artist
                }
                start = end
            }
            return ids.compactMap { byID[$0] }
        }
    }

    // MARK: 10. Book members

    func bookPlacement(songID: String) async throws -> (bookID: String, kind: LibraryCatalogContentKind, displayTitle: String?)? {
        try await read { try $0.bookPlacement(songID: songID) }
    }

    /// 书或节目的章节,库内顺序;给了源只留那个源的。
    func bookRowList(bookID: String, sourceID: String? = nil) async throws -> LibraryRowList {
        guard let sourceID else { return try await read { try $0.bookRowList(bookID: bookID) } }
        return try await read { catalog in
            let list = try catalog.bookRowList(bookID: bookID)
            let inSource = try catalog.rowList(.source(sourceID))
            let allowed = Set(inSource.rowids)
            return LibraryRowList(rowids: ContiguousArray(list.rowids.filter { allowed.contains($0) }), revision: list.revision)
        }
    }

    /// 某源里的书 id(流式)。
    func bookIDs(sourceID: String, kind: LibraryCatalogContentKind = .spokenWord) async throws -> [String] {
        try await bookshelf(kind: kind, sourceID: sourceID).map(\.id)
    }

    // MARK: 11. Bookshelf

    /// 书架:所有可见的书或节目,按第一章的库内顺序。进度在 `SpokenWordStore`,调用方合并。
    /// (流式:逐首读归书结果。)
    func bookshelf(kind: LibraryCatalogContentKind, sourceID: String? = nil) async throws -> [LibraryCatalogBook] {
        let scope = LibrarySongScope(kinds: [kind], sourceID: sourceID)
        return try await read { catalog in
            struct Accumulator { var count: Int; let first: String; var sources: Set<String> }
            var order: [String] = []
            var books: [String: Accumulator] = [:]
            var identities: [(String, String)] = []
            try catalog.forEachSong(scope) { _, song in
                identities.append((song.id, song.sourceID))
                return true
            }
            for (songID, songSourceID) in identities {
                guard let placement = try catalog.bookPlacement(songID: songID), placement.kind == kind else { continue }
                if var existing = books[placement.bookID] {
                    existing.count += 1
                    existing.sources.insert(songSourceID)
                    books[placement.bookID] = existing
                } else {
                    order.append(placement.bookID)
                    books[placement.bookID] = Accumulator(count: 1, first: songID, sources: [songSourceID])
                }
            }
            return order.compactMap { id in
                books[id].map { LibraryCatalogBook(id: id, kind: kind, songCount: $0.count, firstSongID: $0.first, sourceIDs: $0.sources) }
            }
        }
    }

    // MARK: 12. Paged sorted lists

    /// 歌曲列表:15 种排序 × 升降,可限定源、只看已下载,可带汇总。
    func songRowList(order: LibrarySongSortOrder, scope: LibrarySongScope = .visibleMusic, includeAggregates: Bool = false) async throws -> LibraryRowList {
        try await read { try $0.songRowList(order: order, scope: scope, includeAggregates: includeAggregates) }
    }

    func albumKeyList(visibleOnly: Bool = true) async throws -> LibraryCatalogKeyList {
        try await read { try $0.albumKeys(visibleOnly: visibleOnly) }
    }

    func artistKeyList(visibleOnly: Bool = true) async throws -> LibraryCatalogKeyList {
        try await read { try $0.artistKeys(visibleOnly: visibleOnly) }
    }

    func albums(keys: [Int32], visibleCounts: Bool = true) async throws -> [Album] {
        try await read { try $0.albums(keys: keys, visibleCounts: visibleCounts) }
    }

    func artists(keys: [Int32], visibleCounts: Bool = true) async throws -> [Artist] {
        try await read { try $0.artists(keys: keys, visibleCounts: visibleCounts) }
    }

    // MARK: 13. First K / seeded random K

    func firstSongs(_ scope: LibrarySongScope, limit: Int) async throws -> [Song] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            try catalog.songs(rowids: catalog.rowList(scope).rowids.prefix(cap))
        }
    }

    /// 带种子的随机抽 `count` 首;`requiresArtwork` 时只要有封面引用的(多抽几轮补足)。
    func randomSongs(_ scope: LibrarySongScope, count: Int, seed: UInt64, requiresArtwork: Bool = false) async throws -> [Song] {
        let cap = Self.cap(count)
        return try await read { catalog in
            let rowids = try catalog.rowList(scope).rowids
            var generator = SeededGenerator(seed: seed)
            var order = Array(rowids.indices)
            order.shuffle(using: &generator)
            var result: [Song] = []
            var cursor = 0
            while result.count < cap, cursor < order.count {
                let batchEnd = min(order.count, cursor + max(cap - result.count, 1) * (requiresArtwork ? 4 : 1))
                let batch = order[cursor..<batchEnd].map { rowids[$0] }
                for song in try catalog.songs(rowids: batch)
                where !requiresArtwork || song.coverArtFileName?.isEmpty == false {
                    result.append(song)
                    if result.count == cap { break }
                }
                cursor = batchEnd
            }
            return result
        }
    }

    // MARK: 14. Recently added

    func recentlyAddedSongs(limit: Int, scope: LibrarySongScope = .visibleMusic) async throws -> [Song] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            try catalog.songs(rowids: catalog.songRowList(order: .dateAdded, scope: scope).rowids.prefix(cap))
        }
    }

    /// 按专辑内最大加入时间排的专辑 id(沿加入时间降序走歌,取前 `limit` 个不同的专辑)。
    func recentlyAddedAlbumIDs(limit: Int, scope: LibrarySongScope = .visibleMusic) async throws -> [String] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            let rowids = try catalog.songRowList(order: .dateAdded, scope: scope).rowids
            var seen = Set<String>()
            var result: [String] = []
            var start = 0
            while start < rowids.count, result.count < cap {
                let end = min(rowids.count, start + 500)
                for song in try catalog.songs(rowids: rowids[start..<end]) {
                    guard let albumID = song.albumID, seen.insert(albumID).inserted else { continue }
                    result.append(albumID)
                    if result.count == cap { break }
                }
                start = end
            }
            return result
        }
    }

    // MARK: 15. Playback cursor

    /// 全部可播放音乐的行号(不含不喜欢的),库内顺序或按种子打乱。播放全部、随机全部、
    /// 从这首开始、随机续接用;播放器只物化窗口。
    func playbackRowList(shuffledWithSeed seed: UInt64? = nil, excludingSongIDs excluded: Set<String> = []) async throws -> LibraryRowList {
        try await read { catalog in
            let list = try catalog.rowList(LibrarySongScope(kinds: [.music], playableOnly: true))
            var rowids = list.rowids
            if !excluded.isEmpty {
                let excludedRowids = Set(try catalog.rowids(forIDs: Array(excluded.prefix(LibraryScale.maxMaterializedRows))).compactMap { $0 })
                rowids = ContiguousArray(rowids.filter { !excludedRowids.contains($0) })
            }
            if let seed {
                var generator = SeededGenerator(seed: seed)
                rowids.shuffle(using: &generator)
            }
            return LibraryRowList(rowids: rowids, revision: list.revision)
        }
    }

    // MARK: 16. Search (top-K)

    /// 歌曲搜索前 `limit` 个:标题、艺人、专辑里含查询词(不分大小写、全半角、变音)。
    /// (流式;目录接上全文索引后换掉。)
    func searchSongs(_ query: String, limit: Int, scope: LibrarySongScope = .visible) async throws -> [Song] {
        let needle = Self.searchKey(query)
        let cap = Self.cap(limit)
        guard !needle.isEmpty, cap > 0 else { return [] }
        return try await read { catalog in
            var titleHits: [Song] = []
            var otherHits: [Song] = []
            try catalog.forEachSong(scope) { _, song in
                if Self.searchKey(song.title).contains(needle) {
                    titleHits.append(song)
                } else if otherHits.count < cap,
                          Self.searchKey(song.artistName ?? "").contains(needle)
                            || Self.searchKey(song.albumTitle ?? "").contains(needle) {
                    otherHits.append(song)
                }
                return titleHits.count < cap
            }
            return Array((titleHits + otherHits).prefix(cap))
        }
    }

    func searchAlbums(_ query: String, limit: Int) async throws -> [Album] {
        let needle = Self.searchKey(query)
        let cap = Self.cap(limit)
        guard !needle.isEmpty, cap > 0 else { return [] }
        return try await read { catalog in
            let keys = try catalog.albumKeys(visibleOnly: true).keys
            var result: [Album] = []
            var start = 0
            while start < keys.count, result.count < cap {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for album in try catalog.albums(keys: keys[start..<end])
                where Self.searchKey(album.title).contains(needle) || Self.searchKey(album.artistName ?? "").contains(needle) {
                    result.append(album)
                    if result.count == cap { break }
                }
                start = end
            }
            return result
        }
    }

    func searchArtists(_ query: String, limit: Int) async throws -> [Artist] {
        let needle = Self.searchKey(query)
        let cap = Self.cap(limit)
        guard !needle.isEmpty, cap > 0 else { return [] }
        return try await read { catalog in
            let keys = try catalog.artistKeys(visibleOnly: true).keys
            var result: [Artist] = []
            var start = 0
            while start < keys.count, result.count < cap {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for artist in try catalog.artists(keys: keys[start..<end]) where Self.searchKey(artist.name).contains(needle) {
                    result.append(artist)
                    if result.count == cap { break }
                }
                start = end
            }
            return result
        }
    }

    static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 17. External identity match

    /// 外部条目(歌单导入、服务器镜像、备份恢复)对应的库内歌曲:规范化歌名 + 歌手,
    /// 时长兜底(`ExternalTrackMatchPolicy`)。每个条目给出最好的那首(可信优先,同档按库内顺序)。
    /// (流式;目录补上 matchKey 索引后换掉。)
    func matchExternal(
        _ subjects: [ExternalTrackMatchPolicy.Subject],
        minimum: ExternalTrackMatchPolicy.Verdict = .probable,
        scope: LibrarySongScope = .visible
    ) async throws -> [String?] {
        let queries = subjects.prefix(LibraryScale.maxMaterializedRows).map(ExternalTrackMatchPolicy.Key.init)
        guard !queries.isEmpty else { return [] }
        return try await read { catalog in
            var queriesByTitle: [String: [Int]] = [:]
            for (index, key) in queries.enumerated() where key.isMatchable {
                queriesByTitle[key.coreTitle, default: []].append(index)
            }
            var best = [(id: String, verdict: ExternalTrackMatchPolicy.Verdict)?](repeating: nil, count: queries.count)
            try catalog.forEachSong(scope) { _, song in
                let core = ExternalTrackMatchPolicy.normalizedCoreTitle(song.title)
                guard let candidates = queriesByTitle[core] else { return true }
                let key = ExternalTrackMatchPolicy.Key(.init(
                    title: song.title,
                    artists: [song.artistName, song.albumArtistName].compactMap { $0 },
                    duration: song.duration
                ))
                for index in candidates {
                    let verdict = ExternalTrackMatchPolicy.verdict(queries[index], key)
                    guard verdict >= minimum, verdict != .none else { continue }
                    if let current = best[index], current.verdict >= verdict { continue }
                    best[index] = (song.id, verdict)
                }
                return true
            }
            return best.map { $0?.id }
        }
    }

    // MARK: 18. Folder tree

    func folderChildren(sourceID: String, path: String?) async throws -> [LibraryCatalog.FolderEntry] {
        try await read { try $0.folderChildren(sourceID: sourceID, path: path) }
    }

    /// 某文件夹里直接的歌曲(子文件夹用 `folderChildren`)。
    func folderSongRowList(sourceID: String, path: String) async throws -> LibraryRowList {
        try await read { try $0.rowList(sourceID: sourceID, directory: path, recursive: false) }
    }

    // MARK: 19. Maintenance predicates

    /// 满足维护谓词的行(流式)。结果是行号列表,不物化。
    func rowList(matching predicate: LibraryMaintenancePredicate, visibility: LibraryCatalogVisibility = .includingDisabledSources) async throws -> LibraryRowList {
        let scope = LibrarySongScope(kinds: predicate.kinds, includesDisabledSources: visibility.includesDisabledSources)
        return try await filteredRowList(scope) { predicate.matches($0) }
    }

    // MARK: 20. Distinct aggregates

    func totalDuration(_ scope: LibrarySongScope = .visibleMusic) async throws -> TimeInterval {
        try await read { try $0.aggregates(scope).totalDuration }
    }

    /// 不同封面引用的个数(流式;集合大小以封面数为界)。
    func distinctCoverReferenceCount(_ scope: LibrarySongScope = .visible) async throws -> Int {
        try await read { catalog in
            var references = Set<String>()
            try catalog.forEachSong(scope) { _, song in
                if let cover = song.coverArtFileName, !cover.isEmpty { references.insert(cover) }
                return true
            }
            return references.count
        }
    }

    /// 不同的艺人名(合并建议用),按名字本地化排序,至多 `limit` 个。
    func distinctArtistNames(limit: Int) async throws -> [String] {
        let cap = Self.cap(limit)
        return try await read { catalog in
            let keys = try catalog.artistKeys(visibleOnly: true).keys
            var names: [String] = []
            var start = 0
            while start < keys.count, names.count < cap {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                names.append(contentsOf: try catalog.artists(keys: keys[start..<end]).map(\.name))
                start = end
            }
            return Array(names.prefix(cap))
        }
    }

    // MARK: - Helpers

    /// 按库内顺序过滤出行号(流式,内存只占一批 + 结果行号)。
    private func filteredRowList(_ scope: LibrarySongScope, where include: @escaping @Sendable (Song) -> Bool) async throws -> LibraryRowList {
        try await read { catalog in
            let revision = try catalog.revision()
            var rowids = ContiguousArray<Int32>()
            try catalog.forEachSong(scope) { rowid, song in
                if include(song) { rowids.append(rowid) }
                return true
            }
            return LibraryRowList(rowids: rowids, revision: revision)
        }
    }
}

/// 可复现的伪随机(SplitMix64):同一种子、同一列表给出同一顺序。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
