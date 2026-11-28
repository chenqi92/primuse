#if os(iOS)
import Foundation
import PrimuseKit

/// 车机文件夹里的歌在歌曲模型不在内存里时从曲库目录取(C2)。
///
/// 模型在内存里时照旧:索引给 id、按 id 取可见的歌、按碟号、曲号、标题排好(`songs(in:scope:)`)。不在时同一组 id
/// (目录版的分区读目录,读失败时抛出,不当成没有歌)、按 id 分段从目录取可见的歌(每段至多物化上限那么多)、同一个
/// 比较器在主线程外排,先后相同。整个文件夹(连同子树)播放时,一个源的根就是这个源的全部歌:与模型在内存里时一样
/// 物化成一份队列,只是在主线程外、按段读,用完即放。
extension CarPlayFolderLibrary {
    /// 车机文件夹里歌的先后:碟号、曲号,再按标题(`localizedStandardCompare`)。
    nonisolated static func playOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        if lhs.discNumber != rhs.discNumber { return (lhs.discNumber ?? 0) < (rhs.discNumber ?? 0) }
        if lhs.trackNumber != rhs.trackNumber { return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0) }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// 主线程外:节点(或连同子树)的可见歌,先后同 `songs(in:scope:)`。
    nonisolated static func catalogSongs(
        in nodeID: LibraryFolderNodeID, scope: LibraryFolderSongScope, index: LibraryFolderIndex,
        reader: LibraryCatalogReader
    ) async throws -> [Song] {
        try await reader.readCancellable { catalog, cancellation in
            let ids = try LibraryFolderCatalogSongOrder.songIDs(
                in: nodeID, scope: scope, index: index, catalog: catalog, isCancelled: { cancellation.isCancelled }
            )
            var songs: [Song] = []
            songs.reserveCapacity(ids.count)
            var start = 0
            while start < ids.count {
                try cancellation.check()
                let end = min(ids.count, start + LibraryScale.maxMaterializedRows)
                songs.append(contentsOf: try catalog.songs(ids: Array(ids[start..<end]), scope: .visible))
                start = end
            }
            return songs.sorted(by: playOrder)
        }
    }

    /// 播放整个文件夹(连同子树)用的歌,先后同 `songs(in:)`。模型在内存里时当场给(与以前相同);不在时在主线程外
    /// 从目录取,取到了再给;答不出(没有索引、目录读不了、读失败)时什么都不做,不放一份空的或缺了的队列。
    func songs(in id: LibraryFolderNodeID, then play: @escaping @MainActor ([Song]) -> Void) {
        let library = AppServices.shared.musicLibrary
        guard !library.isReady else { return play(songs(in: id)) }
        Task { @MainActor in
            guard let songs = await catalogSongs(in: id, library: library) else { return }
            play(songs)
        }
    }

    /// 同上,模型不在内存里时的那一半:nil 是此刻答不出。
    func catalogSongs(in id: LibraryFolderNodeID, library: MusicLibrary) async -> [Song]? {
        guard let index, let reader = library.readableCatalogReader else { return nil }
        do {
            return try await Self.catalogSongs(in: id, scope: .descendants, index: index, reader: reader)
        } catch {
            plog("🚗 CarPlay folder songs from the catalog failed: \(error)")
            return nil
        }
    }
}
#endif
