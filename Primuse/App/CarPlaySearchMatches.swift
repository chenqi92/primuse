#if os(iOS)
import Foundation
import PrimuseKit

/// 车机「最近搜索」点一条之后列出的歌(至多 100 首)。搜的是全部可见的歌(有声、环境音也在,`musicOnly: false`)。
///
/// 模型在内存里时与以前相同:持久搜索索引给 id,内存里的快照换成歌,索引不可用时逐首搜。不在时(C2)快照从曲库目录取
/// (`LibrarySearchCatalogSnapshot`,范围 `.visible`):同一套「只给扫描会挑中的歌、其余按 id 回查」,命中与名次
/// 与在内存里相同,不读整库数组。目录读不了、读失败时没有结果(搜索页说「没有结果」;与手机上搜索答不出时一样,
/// 见 P3-design 20o)。
@MainActor
enum CarPlaySearchMatches {
    nonisolated static let songLimit = 100

    static func songs(
        matching normalized: String, in library: MusicLibrary, index: LibrarySearchIndex = .shared
    ) async -> [Song] {
        let metadataRevisionKey = "\(library.visibleSongCollectionRevision):\(library.searchRevision)"
        let snapshot: LibrarySearchSongSnapshot
        if library.isReady {
            snapshot = library.searchSongSnapshot(musicOnly: false)
        } else {
            guard let reader = library.readableCatalogReader else { return [] }
            do {
                snapshot = try await LibrarySearchCatalogSnapshot.make(
                    reader: reader, query: normalized, matchKinds: LibrarySearchMatchKind.all, wantsAlbums: false,
                    songLimit: songLimit, sourceTypes: library.searchSources?.typesByID ?? [:], scope: .visible
                )
            } catch {
                plog("🚗 CarPlay search from the catalog failed: \(error)")
                return []
            }
        }
        if let indexed = await index.search(
            query: normalized,
            snapshot: snapshot,
            albums: [],
            metadataRevisionKey: metadataRevisionKey,
            songLimit: songLimit,
            albumLimit: 0
        ) {
            return indexed.output.songResults.map(\.song)
        }
        // 索引不可用时逐首搜要整份歌:只在模型在内存里时做。
        guard library.isReady else { return [] }
        return await Task.detached(priority: .userInitiated) {
            LibrarySearchWorker.compute(
                query: normalized,
                songs: snapshot.songs,
                albums: [],
                cache: LibrarySearchCache(),
                sourceTypes: snapshot.sourceTypes,
                includeMetadata: true,
                includeLyrics: false,
                songLimit: songLimit,
                albumLimit: 0
            ).songResults.map(\.song)
        }.value
    }
}
#endif
