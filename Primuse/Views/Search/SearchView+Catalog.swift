import Foundation
import PrimuseKit

/// 搜索页在歌曲模型不在内存里时从曲库目录答的那几件事(6c 单元 4 U7)。模型在内存里(或第一次装载还没完)时
/// 每一句都照旧读内存模型,一字不差。
@MainActor
enum SearchCatalogSupport {
    /// 模型不在内存里、曲库可用:这一刻搜索页从目录答。
    static func answersFromCatalog(_ library: MusicLibrary) -> Bool {
        !library.isReady && library.isUsable
    }

    /// 资料库一首歌都没有(搜索页的「资料库是空的」):不在内存里时看目录的计数,还没数出来时不算空,
    /// 不把「答不了」当成「没有歌」。
    static func libraryIsEmpty(_ library: MusicLibrary) -> Bool {
        guard answersFromCatalog(library) else {
            // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时问目录计数
            return library.visibleSongs.isEmpty
        }
        guard let counts = LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts else { return false }
        // crash-pattern: allow legacy-library-api 目录计数的字段名,不是整库数组
        return counts.visibleSongs == 0
    }

    enum Count { case music, albums, artists }

    /// Mac 搜索页下面那三格、范围菜单里的数:不在内存里时是目录计数,还没数出来时「—」。
    static func countText(_ count: Count, _ library: MusicLibrary) -> String {
        guard answersFromCatalog(library) else {
            switch count {
            // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时问目录计数
            case .music: return "\(library.musicSongs.count)"
            // crash-pattern: allow legacy-library-api 同上
            case .albums: return "\(library.visibleAlbums.count)"
            // crash-pattern: allow legacy-library-api 同上
            case .artists: return "\(library.visibleArtists.count)"
            }
        }
        guard let counts = LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts else { return "—" }
        switch count {
        case .music: return "\(counts.music)"
        case .albums: return "\(counts.albums)"
        case .artists: return "\(counts.artists)"
        }
    }

    /// 还要整库数组的两支:智能搜索(按语义从整库挑)、范围大到超出一次物化上限的范围搜索。模型不在内存里时
    /// 页面替它们占用模型(`.songModelPage`),装回来照旧;别的都从目录答。
    static func needsTheSongModel(_ library: MusicLibrary, query: String, scope: LibrarySearchScope?, intelligent: Bool) -> Bool {
        guard answersFromCatalog(library), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let scope { return scope.songIDs.count > LibraryScale.maxMaterializedRows }
        return intelligent
    }

    // MARK: Albums and artists

    /// 专辑、艺人的命中从目录准备(`LibraryCatalogCollectionSearch`)时的范围;模型在内存里时 nil(照旧交整份数组)。
    static func collectionScope(_ library: MusicLibrary, albums: Bool, artists: Bool) -> SearchCollectionCatalogScope? {
        guard answersFromCatalog(library), albums || artists, let reader = library.readableCatalogReader,
              let revisions = library.catalogHost?.revisions else { return nil }
        return SearchCollectionCatalogScope(
            reader: reader, catalog: ObjectIdentifier(reader), albums: albums, artists: artists,
            revision: revisions.catalogRevision &* 4 &+ (albums ? 1 : 0) &+ (artists ? 2 : 0)
        )
    }

    /// 要不要「歌名命中带出的专辑」(`LibrarySearchIndex.search` 的 `wantsAlbums`,也决定专辑块开着时要不要搜元数据):
    /// 模型在内存里时同以前看交进去的专辑数组;不在时(C1)专辑块开着、从目录准备专辑就要 —— 不再因为那份数组是空的
    /// 就不要,两种状态下这一句的答案相同。
    static func wantsAlbums(_ albums: [Album], _ catalog: SearchCollectionCatalogScope?) -> Bool {
        !albums.isEmpty || catalog?.albums == true
    }

    /// 专辑、艺人的命中:`catalog` 为 nil 时同以前交给 `index`(内存里的数组);否则从目录准备、打分与先后相同。
    static func collections(
        index: LibraryCatalogSearchIndex, query: String, albums: [Album], artists: [Artist],
        relatedAlbums: [Album] = [], semanticArtists: Bool = false, includePinyin: Bool = true,
        catalog: SearchCollectionCatalogScope?
    ) async -> LibraryCatalogSearchIndex.Output {
        guard let catalog else {
            return await index.search(
                query: query, albums: albums, artists: artists, relatedAlbums: relatedAlbums,
                semanticArtists: semanticArtists, includePinyin: includePinyin
            )
        }
        return await LibraryCatalogCollectionSearch.shared.search(
            query: query, scope: catalog, relatedAlbums: relatedAlbums,
            semanticArtists: semanticArtists, includePinyin: includePinyin
        )
    }

    // MARK: Spoken word and ambient spaces

    /// 有声那一组要分组的条目:同 `spokenWordSongs + localPodcastSongs`(有声书章节在前、本机播客单集在后,
    /// 各自库内顺序),从目录读。读不了时 nil。
    static func catalogSpokenSongs(_ library: MusicLibrary) async -> [Song]? {
        guard let books = await SpokenWordCatalogShelf.songs(.books, in: library),
              let podcasts = await SpokenWordCatalogShelf.songs(.localPodcasts, in: library) else { return nil }
        return books + podcasts
    }

    /// 分好的书按它缓存:不在内存里时跟着目录的归书修订号。
    static func catalogBookRevision(_ library: MusicLibrary) -> UInt64 {
        library.catalogHost?.revisions.books ?? 0
    }

    /// 环境音那一组:同 `ambientSongs`(可见的环境音,库内顺序),从目录读;环境音通常不多,至多
    /// `maxMaterializedRows` 段。读不了时 nil。最近一份留着给点播时排同组的几段。
    static func catalogAmbientSongs(_ library: MusicLibrary) async -> [Song]? {
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            let songs = try await reader.read { catalog in
                let rows = try catalog.rowList(LibrarySongScope(kinds: [.ambient])).rowids
                return try catalog.songs(rowids: rows.prefix(LibraryScale.maxMaterializedRows))
            }
            lastAmbientSongs = songs
            return songs
        } catch {
            plog("🔎 ambient search from the catalog failed: \(error)")
            return nil
        }
    }

    // crash-pattern: allow library-array-property 至多 maxMaterializedRows 段环境音(从目录读时就截在这里)
    private static var lastAmbientSongs: [Song] = []

    /// 点一条环境音时排同组几段用的那份:模型在内存里时同以前读 `ambientSongs`,不在时用刚从目录读的那份。
    static func ambientSongsForPlayback(_ library: MusicLibrary) -> [Song] {
        // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时用目录读出的那份(环境音不多)
        answersFromCatalog(library) ? lastAmbientSongs : library.ambientSongs
    }
}

/// 专辑、艺人命中从目录准备时带的东西:目录、要不要专辑 / 艺人,以及准备按哪一代目录排。
struct SearchCollectionCatalogScope: Sendable {
    let reader: LibraryCatalogReader
    /// 哪一个目录(一个进程里可能有几个曲库,测试里就是):换了目录整代重排。
    let catalog: ObjectIdentifier
    let albums: Bool
    let artists: Bool
    /// 目录的修订号与要不要专辑 / 艺人:变了整代重排。
    let revision: Int64
}

extension SearchCollectionCatalogScope {
    /// 歌名命中带出的专辑按 id 从目录取(C1,交给 `LibrarySearchIndex.search(albumsByID:)`):一次批量的按 id 读
    /// (`albums(visibleIDs:)`,至多 `songLimit * 2` 个 id 的几倍,远在物化上限之内),给的专辑与 `visibleAlbums` 里同
    /// id 的那张相同、不可见的不给。不要专辑时 nil。读失败时空(同旁边按 id 回查歌的那一步:记日志,这一次搜索没有
    /// 这几张;目录下一次动时搜索页重搜)。
    var albumsByID: (@Sendable (Set<String>) async -> [String: Album])? {
        guard albums else { return nil }
        let reader = self.reader
        return { ids in
            do {
                let found = try await reader.read { try $0.albums(visibleIDs: ids) }
                return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                if !(error is CancellationError) {
                    plog("🔎 Song-matched albums from the catalog failed: \(error.localizedDescription)")
                }
                return [:]
            }
        }
    }
}

/// 搜索页专辑、艺人的命中在歌曲模型不在内存里时从曲库目录来(Q5,6c 单元 4 U7):同一个搜索库、同一套预处理与
/// 打分(`LibraryCollectionSearchStore.searchRows`),专辑按专辑墙的先后、艺人按艺人列表的先后一块块准备,
/// 不留整份数组;命中的 id 再按 id 从目录取。成员、先后(含同分时的先后)与模型在内存里时相同。
actor LibraryCatalogCollectionSearch {
    static let shared = LibraryCatalogCollectionSearch()

    private let store: LibraryCollectionSearchStore?
    private var preparedFor: (catalog: ObjectIdentifier, revision: Int64)?
    private var generation: Int64 = 0

    init() {
        if let database = LibrarySearchIndex.shared.collectionSearchDatabase {
            store = LibraryCollectionSearchStore(writer: database)
        } else {
            store = try? LibraryCollectionSearchStore.temporary()
        }
    }

    func search(
        query: String, scope: SearchCollectionCatalogScope, relatedAlbums: [Album],
        semanticArtists: Bool, includePinyin: Bool
    ) async -> LibraryCatalogSearchIndex.Output {
        let empty = LibraryCatalogSearchIndex.Output(albums: [], artists: [])
        guard let store else { return empty }
        if preparedFor?.catalog != scope.catalog || preparedFor?.revision != scope.revision {
            preparedFor = (scope.catalog, scope.revision)
            generation &+= 1
        }
        let generation = generation
        do {
            let catalog = try await scope.reader.catalogHandle()
            var albumKeys: ContiguousArray<Int32>?
            var artistKeys: ContiguousArray<Int32>?
            let chunk = LibraryScale.maxMaterializedRows
            let ids = try store.searchRows(
                query: query,
                generation: generation,
                albumRows: { index in
                    guard scope.albums else { return [] }
                    if albumKeys == nil { albumKeys = try catalog.albumKeys(visibleOnly: true).keys }
                    guard let keys = albumKeys, index * chunk < keys.count else { return [] }
                    return try catalog.albums(keys: keys[(index * chunk)..<min(keys.count, (index + 1) * chunk)])
                        .map { .init(id: $0.id, text: $0.title, secondary: $0.artistName ?? "") }
                },
                artistRows: { index in
                    guard scope.artists else { return [] }
                    if artistKeys == nil { artistKeys = try catalog.artistKeys(visibleOnly: true).keys }
                    guard let keys = artistKeys, index * chunk < keys.count else { return [] }
                    return try catalog.artists(keys: keys[(index * chunk)..<min(keys.count, (index + 1) * chunk)])
                        .map { .init(id: $0.id, text: $0.name) }
                },
                relatedAlbumIDs: relatedAlbums.map(\.id),
                semanticArtists: semanticArtists,
                includePinyin: includePinyin,
                isCancelled: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return empty }
            let albums = try catalog.albums(visibleIDs: ids.albumIDs.prefix(LibraryScale.maxMaterializedRows))
            var artists: [Artist] = []
            for id in ids.artistIDs.prefix(LibraryScale.maxMaterializedRows) {
                if let artist = try catalog.visibleArtist(id: id) { artists.append(artist) }
            }
            return LibraryCatalogSearchIndex.Output(albums: albums, artists: artists)
        } catch {
            plog("🔎 Album/artist search from the catalog failed: \(error.localizedDescription)")
            return empty
        }
    }
}
