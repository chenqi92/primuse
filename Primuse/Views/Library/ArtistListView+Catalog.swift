import Foundation
import PrimuseKit
import SwiftUI

/// 资料库艺人页在曲库目录上的数据源(P3;U4b 加上「专辑艺术家」、只看喜欢与 Mac 的先后):按页物化,
/// 与内存路径同序同分段 ——
/// - 「全部艺术家」:iPhone、iPad 按读音(`artistBrowseKeys`,同 `LibraryArtistBrowseLayoutBuilder`),
///   Mac 按艺人列表的先后(`artistKeys`,同 `visibleArtists`);
/// - 「专辑艺术家」:`albumArtistBrowse`(同 `visibleAlbumArtists` / 按读音排的那一份);
/// - 页内搜索在主线程外按块筛名字(同 `localizedCaseInsensitiveContains`);只看喜欢按喜欢的先后
///   (同 `likedArtists(in:)`:按喜欢的键对上,同一个先后保持列表的先后)。
struct LibraryArtistBrowseQuery: LibraryListQuery {
    let unknownArtistName: String
    /// 名字包含(不分大小写);空串不筛。
    let search: String
    var mode: ArtistBrowseMode = .allArtists
    /// 按读音排(iPhone、iPad);假时按艺人列表 / 专辑艺人列表的先后(Mac)。
    var readingOrder = true
    /// 只看喜欢:喜欢的键 → 先后(`FavoriteCatalogLikes.likedOrder`)。nil:不筛。
    var likedOrder: [String: Int]?
    /// 「专辑艺术家」那一份:取行号时存下,按页物化时用。
    let albumArtists = AlbumArtistBrowseBox()

    /// 这一种列法、这一种先后的整列键与分段。
    private func listKeys(_ catalog: LibraryCatalog) throws -> (ContiguousArray<Int32>, [LibraryBrowseSection], Int64) {
        switch (mode, readingOrder) {
        case (.allArtists, true):
            let browse = try catalog.artistBrowseKeys(unknownArtistName: unknownArtistName, visibleOnly: true)
            return (browse.keys, browse.sections, browse.revision)
        case (.allArtists, false):
            let list = try catalog.artistKeys(visibleOnly: true)
            return (list.keys, [], list.revision)
        case (.albumArtists, _):
            let browse = try catalog.albumArtistBrowse(
                order: readingOrder ? .reading(unknownArtistName: unknownArtistName) : .library
            )
            albumArtists.store(browse)
            return (browse.keys, browse.sections, browse.revision)
        }
    }

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let (keys, sections, revision) = try listKeys(catalog)
        guard !search.isEmpty || likedOrder != nil else {
            return LibraryListRows(ids: keys, sections: [], revision: revision, browseSections: sections)
        }
        var kept: [(key: Int32, position: Int, likedOffset: Int)] = []
        var start = 0
        while start < keys.count {
            let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
            let chunk = Array(keys[start..<end])
            let artists = try materialize(chunk, catalog: catalog)
            for (offset, key) in chunk.enumerated() {
                guard let artist = artists[key] else { continue }
                if !search.isEmpty, !artist.name.localizedCaseInsensitiveContains(search) { continue }
                var likedOffset = 0
                if let likedOrder {
                    let favoriteKey = LibraryFavoriteKey.id(
                        kind: .artist, albumTitle: "", artistName: artist.name, unknownArtistName: unknownArtistName
                    )
                    guard let found = likedOrder[favoriteKey] else { continue }
                    likedOffset = found
                }
                kept.append((key, start + offset, likedOffset))
            }
            start = end
        }
        if likedOrder != nil {
            // 只看喜欢:按喜欢的先后(字母条收起,不分段)。
            kept.sort { $0.likedOffset != $1.likedOffset ? $0.likedOffset < $1.likedOffset : $0.position < $1.position }
            return LibraryListRows(ids: ContiguousArray(kept.map(\.key)), sections: [], revision: revision)
        }
        return LibraryListRows(
            ids: ContiguousArray(kept.map(\.key)), sections: [], revision: revision,
            browseSections: LibraryBrowseLayout<Artist>.sections(sections, keeping: kept.map(\.position))
        )
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Artist] {
        try materialize(ids, catalog: catalog)
    }

    private func materialize(_ ids: [Int32], catalog: LibraryCatalog) throws -> [Int32: Artist] {
        guard mode == .allArtists else {
            guard let browse = albumArtists.browse else { return [:] }
            return try catalog.albumArtists(keys: ids, in: browse)
        }
        // `artists(keys:)` 保持顺序、跳过不在的键:数目对得上就按位置对回键,否则一个个取。
        let artists = try catalog.artists(keys: ids, visibleCounts: true)
        if artists.count == ids.count { return Dictionary(uniqueKeysWithValues: zip(ids, artists)) }
        var result: [Int32: Artist] = [:]
        for key in ids {
            if let artist = try catalog.artists(keys: [key], visibleCounts: true).first { result[key] = artist }
        }
        return result
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}

/// 「专辑艺术家」那一份(行号与每行的专辑数),取行号的那一次存、按页物化时读。
final class AlbumArtistBrowseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LibraryAlbumArtistBrowse?

    var browse: LibraryAlbumArtistBrowse? { lock.withLock { stored } }

    func store(_ browse: LibraryAlbumArtistBrowse) { lock.withLock { stored = browse } }
}

struct ArtistCatalogKey: Hashable, Sendable {
    let search: String
    var mode: ArtistBrowseMode = .allArtists
    /// 只看喜欢时喜欢的账本的修订号(账本变了重查);不只看喜欢时 nil。
    var likedRevision: Int?
}

extension ArtistCatalogKey {
    /// 资料库艺人页此刻走不走曲库目录、走哪一份。歌曲模型在内存里时同以前:只有「全部艺术家」、不只看喜欢
    /// (`requiresEmptySearch`:Mac 还要不在查找)。不在内存里时(U4b)各种列法、查找、只看喜欢都走目录,
    /// 只有「专辑艺术家」去掉只有单曲的人除外 —— 那要专辑分类,目录没有,页面占用模型。nil:读内存模型。
    @MainActor
    static func current(
        pagesLibrary: Bool, mode: ArtistBrowseMode, likedOnly: Bool, search: String, hidesSingles: Bool,
        requiresEmptySearch: Bool, library: MusicLibrary
    ) -> ArtistCatalogKey? {
        guard pagesLibrary, library.catalogHost?.revisions.isReadable == true else { return nil }
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if library.isReady {
            guard mode == .allArtists, !likedOnly, !requiresEmptySearch || search.isEmpty else { return nil }
        } else if mode == .albumArtists, hidesSingles {
            return nil
        }
        return ArtistCatalogKey(
            search: search, mode: mode, likedRevision: likedOnly ? LibraryFavoritesStore.shared.revision : nil
        )
    }

    @MainActor
    func query(readingOrder: Bool) -> LibraryArtistBrowseQuery {
        LibraryArtistBrowseQuery(
            unknownArtistName: String(localized: "unknown_artist"), search: search, mode: mode, readingOrder: readingOrder,
            likedOrder: likedRevision == nil ? nil : FavoriteCatalogLikes.likedOrder(.shared, .artist)
        )
    }

    /// 歌曲模型不在内存里时资料库里一个艺人都没有(目录数出来没有艺人、也没有专辑);还没数出来时不算。
    @MainActor
    static func libraryHasNoArtists(_ library: MusicLibrary) -> Bool {
        LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts.map { $0.artists == 0 && $0.albums == 0 } ?? false
    }
}

typealias ArtistCatalogList = LibraryCatalogBrowseList<LibraryArtistBrowseQuery, ArtistCatalogKey>

/// 还没物化到的艺人格:与 `artistGridCell` 同样的尺寸。
struct ArtistGridCellPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Circle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
            Text(verbatim: "Artist")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .redacted(reason: .placeholder)
        }
        .accessibilityHidden(true)
    }
}

/// 还没物化到的艺人行:与 `artistListRow` 同样的高度。
struct ArtistListRowPlaceholder: View {
    let trailingPadding: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.quaternary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Artist name").font(.body).lineLimit(1)
                Text(verbatim: "1 album · 10 songs").font(.caption).lineLimit(1)
            }
            .redacted(reason: .placeholder)
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }
}
