import Foundation
import PrimuseKit

/// 「目录」页、首页目录卡片和歌曲页目录版式上作用于整个文件夹的那几样要的歌(6c 单元 4 U9a):页面列出的歌与先后、
/// 「播放」的队列、「下载整个文件夹」、「专辑元数据」。
///
/// 模型在内存里时照旧按可见歌(排序、建请求在主线程外)。放掉了(或这次启动没装)时从曲库目录取,在主线程外分段读;
/// 目录答不了(读失败,或要整首歌才能排而歌太多)时占用歌曲模型、照内存的做法。结果为 nil 是「答不了」:调用方什么都不做、
/// 保留原样,不当成「文件夹里没有歌」—— 尤其是会下载、会改标签的操作。
@MainActor
enum HomeFolderSongs {
    /// 等歌曲模型装回来的办法。
    enum Wait {
        /// 页面在排它自己的歌:等到页面走开为止(任务取消时撤掉占用,不再要求装)。
        case page
        /// 一次操作(播放、下载、专辑元数据):至多等 `actionTimeout`,等不到就不做。
        case action
    }

    struct Ordered: Equatable {
        let ids: [String]
        /// 从曲库目录排出来时与 `ids` 一一对应的行号(行按页物化用);照内存排的是 nil。
        let rowids: ContiguousArray<Int32>?
    }

    /// 一次操作等模型的上限(测试里改短)。
    static var actionTimeout: Duration = SongModelArrayRead.defaultTimeout
    /// 要整首歌才能排的顺序在目录上一次至多排多少首,超过就占用模型照内存排(测试里改小)。
    static var catalogSongLimit = LibraryScale.maxMaterializedRows
}

extension HomeFolderSongs {
    /// 文件夹里的歌,按「目录」页选的顺序:`.displayed` 是页面列出的(同 `LibraryFolderBrowsePolicy.displayedSongIDs`),
    /// `.descendants` 是「播放」整个文件夹的队列。与模型在内存里时按可见歌排的逐首相同(`LibraryFolderCatalogSongOrder`)。
    static func ordered(
        in nodeID: LibraryFolderNodeID,
        scope: LibraryFolderCatalogSongOrder.Scope,
        index: LibraryFolderIndex,
        order: HomeFolderSongOrder,
        spokenWordSongIDs: Set<String>,
        library: MusicLibrary,
        wait: Wait
    ) async -> Ordered? {
        if !library.isReady {
            do {
                if let reader = library.readableCatalogReader {
                    let limit = catalogSongLimit
                    let answer = try await reader.readCancellable { catalog, cancellation in
                        try LibraryFolderCatalogSongOrder.ordered(
                            in: nodeID, scope: scope, index: index, order: order, spokenWordSongIDs: spokenWordSongIDs,
                            catalog: catalog, songLimit: limit, isCancelled: { cancellation.isCancelled }
                        )
                    }
                    // nil:这种顺序要整首歌而歌太多,照内存排(下面占用模型)。
                    if let answer { return Ordered(ids: answer.ids, rowids: answer.rowids) }
                }
            } catch is CancellationError {
                return nil
            } catch {
                plog("⚠️ Folder song order from the catalog failed, using the song model: \(error)")
            }
            guard !Task.isCancelled else { return nil }
        }
        guard let lookup = await memoryLookup(library, wait: wait) else { return nil }
        let ids = await Task.detached(priority: .userInitiated) {
            let ids = scope == .displayed
                ? LibraryFolderBrowsePolicy.displayedSongIDs(in: index, of: nodeID)
                : index.songIDs(in: nodeID, scope: .descendants)
            return LibraryFolderBrowsePolicy.sortedSongs(
                ids.compactMap { lookup.song(id: $0) }, order: order, spokenWordSongIDs: spokenWordSongIDs
            ).map(\.id)
        }.value
        return Ordered(ids: ids, rowids: nil)
    }

    /// 「下载整个文件夹」的请求,与模型在内存里时按可见歌建的相同(`FolderOfflineDownloadRequest`)。
    /// 外层 nil = 答不了(不弹确认、不下载);内层 nil = 文件夹里没有能下载的歌(同原来,不弹)。
    static func offlineRequest(
        node: LibraryFolderNode,
        index: LibraryFolderIndex,
        library: MusicLibrary,
        source: MusicSource?,
        cloudBackedLocalSourceIDs: Set<String>
    ) async -> FolderOfflineDownloadRequest?? {
        let nodeID = node.id
        if !library.isReady, let reader = library.readableCatalogReader {
            do {
                return try await reader.readCancellable { catalog, cancellation -> FolderOfflineDownloadRequest?? in
                    // 整棵子树的 id(读失败就抛,不当成空文件夹),可见歌按 id 分段取(每段至多物化上限那么多),
                    // 交给同一套规则挑能下载的。
                    let ids = try LibraryFolderCatalogSongOrder.songIDs(
                        in: nodeID, scope: .descendants, index: index, catalog: catalog, isCancelled: { cancellation.isCancelled }
                    )
                    let songs = try catalogSongs(ids, catalog: catalog, cancellation: cancellation)
                    let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    return .some(FolderOfflineDownloadRequest(
                        nodeID: nodeID, songIDs: ids, source: source, cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs,
                        songForID: { byID[$0] }
                    ))
                }
            } catch is CancellationError {
                return nil
            } catch {
                plog("⚠️ Folder download songs from the catalog failed, using the song model: \(error)")
            }
        }
        guard let lookup = await memoryLookup(library, wait: .action) else { return nil }
        let request = await Task.detached(priority: .userInitiated) {
            FolderOfflineDownloadRequest(
                nodeID: nodeID, index: index, source: source, cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs,
                songForID: lookup.song
            )
        }.value
        return .some(request)
    }

    /// 「专辑元数据」那张表要的歌:`ids` 里的可见歌,先后不变(同 `ids.compactMap(unobservedVisibleSong)`)。
    /// 模型在内存里时当场交给 `apply`,与原来相同;放掉了从目录分段取(主线程外),目录答不了时占用模型照内存取,
    /// 还是答不了就不打开(不拿一张空表当成「没有歌」)。
    static func selectBatch(
        ids: [String],
        library: MusicLibrary,
        apply: @escaping @MainActor (BatchSongSelection) -> Void
    ) {
        if library.isReady {
            apply(BatchSongSelection(songs: ids.compactMap { library.unobservedVisibleSong(id: $0) }))
            return
        }
        Task { @MainActor in
            let songs = await batchSongs(library: library, catalogIDs: { _, _ in ids }, memoryIDs: { ids })
            if let songs { apply(BatchSongSelection(songs: songs)) }
        }
    }

    /// 同上,整个文件夹(`index.songIDs(in:scope: .descendants)`);放掉了时连 id 都在主线程外读。
    static func selectBatch(
        in nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex?,
        library: MusicLibrary,
        apply: @escaping @MainActor (BatchSongSelection) -> Void
    ) {
        guard let index else { return selectBatch(ids: [], library: library, apply: apply) }
        if library.isReady {
            return selectBatch(ids: index.songIDs(in: nodeID, scope: .descendants), library: library, apply: apply)
        }
        let expectsSongs = (index.node(withID: nodeID)?.descendantSongCount ?? 0) > 0
        Task { @MainActor in
            let songs = await batchSongs(library: library, catalogIDs: { catalog, cancellation in
                try LibraryFolderCatalogSongOrder.songIDs(
                    in: nodeID, scope: .descendants, index: index, catalog: catalog, isCancelled: { cancellation.isCancelled }
                )
            }, memoryIDs: {
                // 目录刚答不了:按目录建的索引读 id 也会是空的,那是答不了,不是没有歌。
                let ids = index.songIDs(in: nodeID, scope: .descendants)
                return ids.isEmpty && expectsSongs ? nil : ids
            })
            if let songs { apply(BatchSongSelection(songs: songs)) }
        }
    }

    /// id 与歌在目录上读(主线程外);目录答不了时占用模型、照内存按 id 取。nil = 答不了。
    private static func batchSongs(
        library: MusicLibrary,
        catalogIDs: @escaping @Sendable (LibraryCatalog, LibraryCatalogScanCancellation) throws -> [String],
        memoryIDs: @MainActor () -> [String]?
    ) async -> [Song]? {
        if let reader = library.readableCatalogReader {
            do {
                return try await reader.readCancellable { catalog, cancellation in
                    try catalogSongs(catalogIDs(catalog, cancellation), catalog: catalog, cancellation: cancellation)
                }
            } catch {
                plog("⚠️ Folder album metadata songs from the catalog failed, using the song model: \(error)")
            }
        }
        guard let token = await SongModelArrayRead.hold(library, timeout: actionTimeout) else { return nil }
        defer { token.end() }
        return memoryIDs()?.compactMap { library.unobservedVisibleSong(id: $0) }
    }

    /// 内存里那条路要的可见歌查找表。模型不在内存里时先占用:页面等到它走开为止,操作至多等 `actionTimeout`;
    /// 等不到(或任务取消)是 nil。占用只到取完这一份为止,查找表是写时复制的快照,排序、建请求用完即放。
    private static func memoryLookup(_ library: MusicLibrary, wait: Wait) async -> VisibleSongLookup? {
        var hold: MusicLibrary.SongModelHold?
        defer { hold?.end() }
        if !library.isReady {
            switch wait {
            case .page: hold = await library.holdSongModel(.legacyPage)
            case .action: hold = await SongModelArrayRead.hold(library, timeout: actionTimeout)
            }
            guard library.isReady, !Task.isCancelled else { return nil }
        }
        // crash-pattern: allow legacy-library-api 模型在内存里(原路径,或刚为这一下占用、装回来)时才读;只在主线程外排序、建请求时用,用完即放
        return library.visibleSongLookup()
    }

    /// 按 id 分段取可见的歌,保持先后,不在的跳过;每段至多物化上限那么多。
    nonisolated private static func catalogSongs(
        _ ids: [String], catalog: LibraryCatalog, cancellation: LibraryCatalogScanCancellation
    ) throws -> [Song] {
        var songs: [Song] = []
        songs.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            try cancellation.check()
            let end = min(ids.count, start + LibraryScale.maxMaterializedRows)
            songs.append(contentsOf: try catalog.songs(ids: Array(ids[start..<end]), scope: .visible))
            start = end
        }
        return songs
    }
}
