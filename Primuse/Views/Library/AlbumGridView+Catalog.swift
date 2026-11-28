import Foundation
import Observation
import PrimuseKit
import SwiftUI

/// 专辑页在曲库目录上的数据源(P3):目录按读音排好的键(按艺术家、标题、年份),
/// 页内搜索、只看喜欢、隐藏单曲专辑在主线程外按块筛掉,分段随之重切;专辑按页物化。
/// 结果与内存路径(`AlbumGridOrder.layout` + `AlbumGridFilterRequest.filter`)一致。
struct LibraryAlbumBrowseQuery: LibraryListQuery {
    let order: LibraryAlbumBrowseOrder
    /// 按专辑的歌曲数从多到少(同数按标题顺序),同内存路径 `AlbumGridOrder.layout(.songCount)`。
    var bySongCount = false
    let unknownArtistName: String
    let currentYear: Int
    /// nil:不筛。
    let predicate: AlbumGridAlbumPredicate?

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
        guard let predicate, !predicate.isEmpty else {
            return LibraryListRows(ids: browse.keys, sections: [], revision: browse.revision, browseSections: browse.sections)
        }
        var keys = ContiguousArray<Int32>()
        var kept: [Int] = []
        var start = 0
        while start < browse.keys.count {
            let end = min(browse.keys.count, start + LibraryScale.maxMaterializedRows)
            let chunk = Array(browse.keys[start..<end])
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
                kept.append(start + offset)
            }
            start = end
        }
        return LibraryListRows(
            ids: keys, sections: [], revision: browse.revision,
            browseSections: LibraryBrowseLayout<Album>.sections(browse.sections, keeping: kept)
        )
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Album] {
        try LibraryAlbumListQuery(visibleOnly: true).materialize(ids, catalog: catalog, rowCache: rowCache)
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
