import Foundation
import PrimuseKit
import SwiftUI

/// 资料库艺人页(iOS「全部艺术家」)在曲库目录上的数据源(P3):目录按读音排好的键与首字母分段,
/// 页内搜索在主线程外按块筛名字,艺人按页物化。与内存路径(`LibraryArtistBrowseLayoutBuilder`
/// 排好再按名字筛)同序同分段。
struct LibraryArtistBrowseQuery: LibraryListQuery {
    let unknownArtistName: String
    /// 名字包含(不分大小写);空串不筛。
    let search: String

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let browse = try catalog.artistBrowseKeys(unknownArtistName: unknownArtistName, visibleOnly: true)
        guard !search.isEmpty else {
            return LibraryListRows(ids: browse.keys, sections: [], revision: browse.revision, browseSections: browse.sections)
        }
        var keys = ContiguousArray<Int32>()
        var kept: [Int] = []
        var start = 0
        while start < browse.keys.count {
            let end = min(browse.keys.count, start + LibraryScale.maxMaterializedRows)
            let chunk = Array(browse.keys[start..<end])
            // `artists(keys:)` 保持顺序、跳过不在的键:数目对得上就按位置对回键,否则一个个取。
            let artists = try catalog.artists(keys: chunk, visibleCounts: true)
            for (offset, key) in chunk.enumerated() {
                let artist: Artist?
                if artists.count == chunk.count {
                    artist = artists[offset]
                } else {
                    artist = try catalog.artists(keys: [key], visibleCounts: true).first
                }
                guard let artist, artist.name.localizedCaseInsensitiveContains(search) else { continue }
                keys.append(key)
                kept.append(start + offset)
            }
            start = end
        }
        return LibraryListRows(
            ids: keys, sections: [], revision: browse.revision,
            browseSections: LibraryBrowseLayout<Artist>.sections(browse.sections, keeping: kept)
        )
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Artist] {
        try LibraryArtistListQuery(visibleOnly: true).materialize(ids, catalog: catalog, rowCache: rowCache)
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}

struct ArtistCatalogKey: Hashable, Sendable {
    let search: String
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
