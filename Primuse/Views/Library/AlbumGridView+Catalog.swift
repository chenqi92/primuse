import Foundation
import Observation
import PrimuseKit
import SwiftUI

/// 专辑页在曲库目录上的数据源(P3):目录按读音排好的键(按艺术家、标题、年份),
/// 页内搜索、只看喜欢、隐藏单曲专辑在主线程外按块筛掉,分段随之重切;专辑按页物化。
/// 按发行类别筛(RC-b)只看键:与目录里那一类的专辑键求交,保持浏览的先后。
/// 结果与内存路径(`AlbumGridOrder.layout` + `AlbumGridFilterRequest.filter`)一致。
struct LibraryAlbumBrowseQuery: LibraryListQuery {
    let order: LibraryAlbumBrowseOrder
    /// 按专辑的歌曲数从多到少(同数按标题顺序),同内存路径 `AlbumGridOrder.layout(.songCount)`。
    var bySongCount = false
    let unknownArtistName: String
    let currentYear: Int
    /// nil:不筛。
    let predicate: AlbumGridAlbumPredicate?
    /// 按发行类别筛:类别与手动选的发行类别(按歌记的在目录里对到专辑,同 `resolvedReleaseOverrides`);nil:不筛。
    var releaseFilter: (category: AlbumReleaseCategory, choices: AlbumReleaseCategoryStore.Snapshot)?

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let browse: LibraryCatalogBrowseKeys
        if bySongCount {
            guard let byTitle = try catalog.albumBrowseKeys(
                order: .title, unknownArtistName: unknownArtistName, currentYear: currentYear, visibleOnly: true
            ) else { return .empty }
            browse = try Self.sortedBySongCount(byTitle, catalog: catalog)
        } else if order == .recentlyAdded {
            // S5c:同 `RecentlyAddedAlbumPolicy.sorted(albums: visibleAlbums, songs: visibleSongs)`。
            browse = try catalog.recentlyAddedAlbumBrowseKeys()
        } else {
            guard let keys = try catalog.albumBrowseKeys(
                order: order, unknownArtistName: unknownArtistName, currentYear: currentYear, visibleOnly: true
            ) else { return .empty }
            browse = keys
        }
        let inCategory = try releaseCategoryKeys(catalog)
        let predicate = predicate.flatMap { $0.isEmpty ? nil : $0 }
        guard inCategory != nil || predicate != nil else {
            return LibraryListRows(ids: browse.keys, sections: [], revision: browse.revision, browseSections: browse.sections)
        }
        var keys = ContiguousArray<Int32>()
        var kept: [Int] = []
        var start = 0
        while start < browse.keys.count {
            let end = min(browse.keys.count, start + LibraryScale.maxMaterializedRows)
            // 先按发行类别筛(只看键),剩下的才物化来看页内的筛选条件。
            let positions = (start..<end).filter { inCategory?.contains(browse.keys[$0]) ?? true }
            start = end
            guard let predicate else {
                for position in positions {
                    keys.append(browse.keys[position])
                    kept.append(position)
                }
                continue
            }
            let chunk = positions.map { browse.keys[$0] }
            // `albums(keys:)` 保持顺序、跳过不在的键:数目对得上就按位置对回键,否则一个个取。
            let albums = try catalog.albums(keys: chunk, visibleCounts: true)
            for (offset, key) in chunk.enumerated() {
                let album: Album?
                if albums.count == chunk.count {
                    album = albums[offset]
                } else {
                    album = try catalog.albums(keys: [key], visibleCounts: true).first
                }
                guard let album, predicate.matches(album) else { continue }
                keys.append(key)
                kept.append(positions[offset])
            }
        }
        return LibraryListRows(
            ids: keys, sections: [], revision: browse.revision,
            browseSections: LibraryBrowseLayout<Album>.sections(browse.sections, keeping: kept)
        )
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Album] {
        try LibraryAlbumListQuery(visibleOnly: true).materialize(ids, catalog: catalog, rowCache: rowCache)
    }

    /// 按发行类别筛时那一类的专辑键(`LibraryReleaseCategoryFilter`);不筛时 nil。答不出(发行类别还没算齐、目录读不了)
    /// 时抛错:页面改走内存路径(`LibraryCatalogBrowseList` 记下失败的那组条件),不把「答不出」当成这一类一张都没有。
    private func releaseCategoryKeys(_ catalog: LibraryCatalog) throws -> Set<Int32>? {
        guard let releaseFilter else { return nil }
        guard let overrides = LibraryCatalogHost.releaseCategoryOverrides(releaseFilter.choices, catalog: catalog),
              let keys = try LibraryReleaseCategoryFilter(category: releaseFilter.category, overrides: overrides)
                .albumKeys(catalog: catalog) else { throw LibraryCatalogReaderError.unavailable }
        return keys
    }

    /// 标题顺序的键按专辑的(可见)歌曲数稳定地重排:多的在前,一样多的保持标题顺序。分批物化取歌曲数。
    static func sortedBySongCount(_ byTitle: LibraryCatalogBrowseKeys, catalog: LibraryCatalog) throws -> LibraryCatalogBrowseKeys {
        var counts: [Int] = []
        counts.reserveCapacity(byTitle.keys.count)
        var start = 0
        while start < byTitle.keys.count {
            let end = min(byTitle.keys.count, start + LibraryScale.maxMaterializedRows)
            let chunk = Array(byTitle.keys[start..<end])
            let albums = try catalog.albums(keys: chunk, visibleCounts: true)
            if albums.count == chunk.count {
                counts.append(contentsOf: albums.map(\.songCount))
            } else {
                for key in chunk { counts.append(try catalog.albums(keys: [key], visibleCounts: true).first?.songCount ?? 0) }
            }
            start = end
        }
        let order = byTitle.keys.indices.sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
        return LibraryCatalogBrowseKeys(keys: ContiguousArray(order.map { byTitle.keys[$0] }), sections: [], revision: byTitle.revision)
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}

/// 专辑页的筛选条件(目录路径与内存路径共用)。
struct AlbumGridAlbumPredicate: Sendable {
    let query: String
    let likedOnly: Bool
    let hidesSingleSongAlbums: Bool
    let favorites: LibraryFavoriteLedger
    let unknownArtistName: String
    /// 只留这些专辑(离线可放的);nil:不按离线筛。
    var offlineAlbumIDs: Set<String>? = nil

    var isEmpty: Bool { query.isEmpty && !likedOnly && !hidesSingleSongAlbums && offlineAlbumIDs == nil }

    func matches(_ album: Album) -> Bool {
        if let offlineAlbumIDs, !offlineAlbumIDs.contains(album.id) { return false }
        if hidesSingleSongAlbums && album.songCount == 1 { return false }
        if likedOnly && !favorites.isLiked(LibraryFavoriteKey.id(
            kind: .album, albumTitle: album.title, artistName: album.artistName ?? "",
            unknownArtistName: unknownArtistName
        )) { return false }
        if !query.isEmpty && !album.title.localizedCaseInsensitiveContains(query)
            && !(album.artistName?.localizedCaseInsensitiveContains(query) ?? false)
            && !(album.year.map(String.init)?.contains(query) ?? false) { return false }
        return true
    }
}

/// 一组专辑页条件对应的目录列表。条件变了先在后台把新列表取好,再换下旧的(打字搜索时不闪成转圈)。
struct AlbumGridCatalogKey: Hashable, Sendable {
    let order: LibraryAlbumBrowseOrder
    let bySongCount: Bool
    let query: String
    let likedOnly: Bool
    let hidesSingleSongAlbums: Bool
    let favoritesRevision: Int
    /// 只看离线可放的(或全局离线模式):专辑 id 那一份由页面在目录上算好(`offlinePlayableAlbumIDs`)。
    let offlineOnly: Bool
    let offlineRevision: Int
    /// 按发行类别筛(RC-b:目录里的发行类别算齐了才走目录);nil:不筛。
    var releaseCategory: AlbumReleaseCategory?
    /// 按发行类别筛时手动分类的修订号(改了分类重查);不筛时 0。
    var releaseChoicesRevision = 0
}

extension AlbumGridCatalogKey {
    /// 专辑页此刻能不能走目录:目录可读;按发行类别筛时还要目录里的发行类别算齐了(RC-b,在视图里读会跟着变)。
    /// 不能时页面照旧排内存里的专辑(模型不在内存里时先占用装回来)。
    @MainActor
    static func catalogAnswers(_ releaseCategory: AlbumReleaseCategory?, library: MusicLibrary) -> Bool {
        guard let host = library.catalogHost, host.revisions.isReadable else { return false }
        return releaseCategory == nil || host.releaseCategoriesComplete
    }
}

/// 专辑页「补全缺少的简介」那一批:整库专辑,先把模型装回来再按页上的条件筛(6c)。按发行类别筛的目录列表(RC-b)
/// 也按类别筛,与页上相同:手动选的类别先在内存里对好(`resolvedReleaseOverrides`),同内存路径的筛法。
@MainActor
enum AlbumGridIntroFill {
    /// `prepare` 对好的手动分类(专辑 id → 类别,条数是用户手动选过的专辑与歌)。
    private static var preparedOverrides: [String: Set<AlbumReleaseCategory>]?

    /// 把模型装回来;装不回来时 false(不补)。按发行类别筛时顺带对好手动分类。
    static func prepare(_ library: MusicLibrary, releaseCategory: AlbumReleaseCategory?) async -> Bool {
        guard await SongModelArrayRead.read(library, { true }) == true else { return false }
        preparedOverrides = nil
        guard releaseCategory != nil else { return true }
        preparedOverrides = await library.resolvedReleaseOverrides(AlbumReleaseCategoryStore.shared.snapshot)
        return preparedOverrides != nil
    }

    /// 页面走目录时按同样的条件从内存曲库筛(P3 删内存曲库前改成按键分批取);走内存路径时就是页上那一份。
    static func albums(
        catalogKey key: AlbumGridCatalogKey?, filtered: [Album], library: MusicLibrary,
        favorites: LibraryFavoriteLedger, offlineAlbumIDs: Set<String>
    ) -> [Album] {
        guard let key else { return filtered }
        let predicate = AlbumGridAlbumPredicate(
            query: key.query, likedOnly: key.likedOnly, hidesSingleSongAlbums: key.hidesSingleSongAlbums,
            favorites: favorites, unknownArtistName: String(localized: "unknown_artist"),
            offlineAlbumIDs: key.offlineOnly ? offlineAlbumIDs : nil
        )
        // 6c: 整库筛选;点菜单时已先把模型装回来(`prepare`),这里模型在内存里。
        guard library.isReady else { return [] }
        // crash-pattern: allow legacy-library-api 补全简介前已把模型装回来(`prepare`),同原来专辑页的写法,只是搬了文件
        let albums = library.visibleAlbums.filter(predicate.matches)
        guard let category = key.releaseCategory else { return albums }
        let overrides = preparedOverrides ?? [:]
        let categories = library.releaseCategorySnapshot
        return albums.filter { (overrides[$0.id] ?? categories.categories(albumID: $0.id)).contains(category) }
    }
}

/// 一组页面条件对应的目录列表(专辑页、艺人页)。条件变了先在后台把新列表取好,再换下旧的
/// (打字搜索时不闪成转圈);读目录失败的那组条件记下来,页面改走内存路径。
@MainActor
@Observable
final class LibraryCatalogBrowseList<Query: LibraryListQuery, Key: Hashable & Sendable> {
    private(set) var model: LibraryListModel<Query>?
    private(set) var key: Key?
    private(set) var failedKey: Key?

    @ObservationIgnored private var pendingKey: Key?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var railCache: (generation: UInt64, offers: Bool, model: LibraryIndexRailModel?)?
    @ObservationIgnored private let pageSize: Int

    init(pageSize: Int = 120) {
        self.pageSize = pageSize
    }

    func update(_ next: Key, host: LibraryCatalogHost, query: @autoclosure () -> Query) {
        guard next != key, next != pendingKey else { return }
        pendingTask?.cancel()
        pendingKey = next
        let model = LibraryListModel(
            query: query(), reader: host.reader, revisions: host.revisions,
            pageSize: pageSize, prefetchDistance: pageSize
        )
        pendingTask = Task { [weak self] in
            await model.reload()
            guard let self, !Task.isCancelled, self.pendingKey == next else { return }
            self.pendingKey = nil
            if let error = model.lastError {
                plog("📚 catalog browse list read failed (\(error)); using the in-memory library")
                self.failedKey = next
                return
            }
            model.activate(initialReload: false)
            let previous = self.model
            self.model = model
            self.key = next
            self.railCache = nil
            if self.failedKey == next { self.failedKey = nil }
            previous?.deactivate()
        }
    }

    /// 停用当前列表(离开目录路径时)。
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingKey = nil
        model?.deactivate()
        model = nil
        key = nil
        railCache = nil
    }

    /// 右缘字母条:分段没变就沿用同一个模型(界面按身份比较)。
    func railModel(offers: Bool) -> LibraryIndexRailModel? {
        guard let model else { return nil }
        let generation = model.listGeneration
        if let railCache, railCache.generation == generation, railCache.offers == offers { return railCache.model }
        let rail = offers ? LibraryIndexRailModel(sections: model.browseSections) : nil
        let useful = rail?.isUseful == true ? rail : nil
        railCache = (generation, offers, useful)
        return useful
    }
}

typealias AlbumGridCatalogList = LibraryCatalogBrowseList<LibraryAlbumBrowseQuery, AlbumGridCatalogKey>

/// 还没物化到的专辑格:与 `AlbumCardView` 同样的尺寸。
struct AlbumCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Album title").font(.caption).fontWeight(.medium).lineLimit(1)
                Text(verbatim: "Artist").font(.caption2).lineLimit(1)
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityHidden(true)
    }
}
