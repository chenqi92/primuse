import Foundation

/// 歌曲页「目录」版式里一个文件夹的歌,在曲库目录上排(6c 单元 4 U9b)。歌曲模型不在内存里时用,与模型在内存里时
/// 页面给的逐首相同:
/// - 曲目顺序(`listOrder` 为 nil):文件夹索引里的先后(`LibraryFolderIndex.songIDs(in:scope:)`),行号换成 id。
/// - 跟着列表排序:内存里是整页列表(`SongListSnapshotBuilder` 排好的)里属于这个文件夹的那些
///   (`LibraryFolderIndex.orderedSongIDs(in:scope:orderedBy:)`),也就是同一个比较器只对这个文件夹的歌排出的先后
///   (比较器是全序:最后按 id)。这里把同一批歌交给同一个比较器(`SongListSnapshot.sortedSongs(_:order:sortValues:)`,
///   排序值由页面给,与它的内存排序同一份),每首歌在比较器读到的列上与内存里相同:
///   - 标题、文件名、播放次数、来源、已下载只读 id、标题、路径、所在源:按文件夹列取(`folderOrderRecords`,
///     建索引时排一个目录用的同一条查询),不物化整首歌;
///   - 其余排序要整首歌:`songLimit` 首以内按行号分段物化,超过时返回 nil,调用方占用歌曲模型照内存排。
/// - 目录读失败时抛出(调用方当「答不了」,不当成空文件夹);`isCancelled` 为真时抛 `CancellationError`。
///
/// 边界同 `LibraryFolderCatalogSongOrder`:标题或路径含 NUL 的歌,列里存的是替换过的串,按文件夹列排的顺序比的是它。
public enum LibrarySongListFolderOrder {
    /// 每段取多少行。与物化上限相同:一段一个读事务。
    static let chunkSize = LibraryScale.maxMaterializedRows

    public static func ordered(
        in nodeID: LibraryFolderNodeID,
        scope: LibraryFolderSongScope,
        index: LibraryFolderIndex,
        listOrder: LibrarySongSortOrder?,
        sortValues: SongListSortValues = .empty,
        catalog: LibraryCatalog,
        songLimit: Int = LibraryScale.maxMaterializedRows,
        isCancelled: () -> Bool = { false }
    ) throws -> LibraryFolderCatalogSongOrder.Ordered? {
        let rowids = try self.rowids(in: nodeID, scope: scope, index: index, catalog: catalog, isCancelled: isCancelled)
        guard let listOrder else {
            var ids: [String] = []
            var kept = ContiguousArray<Int32>()
            ids.reserveCapacity(rowids.count)
            kept.reserveCapacity(rowids.count)
            for (rowid, song) in try folderColumnSongs(rowids, sourceID: nodeID.sourceID, catalog: catalog, isCancelled: isCancelled) {
                ids.append(song.id)
                kept.append(rowid)
            }
            return LibraryFolderCatalogSongOrder.Ordered(ids: ids, rowids: kept)
        }
        let entries: [(rowid: Int32, song: Song)]
        if readsFolderColumnsOnly(listOrder) {
            entries = try folderColumnSongs(rowids, sourceID: nodeID.sourceID, catalog: catalog, isCancelled: isCancelled)
        } else {
            guard rowids.count <= songLimit else { return nil }
            entries = try wholeSongs(rowids, catalog: catalog, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        let rowidByID = Dictionary(entries.map { ($0.song.id, $0.rowid) }, uniquingKeysWith: { first, _ in first })
        let sorted = SongListSnapshot.sortedSongs(entries.map(\.song), order: listOrder, sortValues: sortValues)
        var ids: [String] = []
        var orderedRowids = ContiguousArray<Int32>()
        ids.reserveCapacity(sorted.count)
        orderedRowids.reserveCapacity(sorted.count)
        for song in sorted {
            guard let rowid = rowidByID[song.id] else { continue }
            ids.append(song.id)
            orderedRowids.append(rowid)
        }
        return LibraryFolderCatalogSongOrder.Ordered(ids: ids, rowids: orderedRowids)
    }

    /// 比较器只读到 id、标题、路径、所在源的排序(见 `SongListSnapshotBuilder.isOrderedBefore` 与 `fileNameKeys`;
    /// 播放次数、已下载按 id 查页面给的排序值,来源按所在源查源名)。
    static func readsFolderColumnsOnly(_ order: LibrarySongSortOrder) -> Bool {
        switch order.criterion {
        case .title, .fileName, .playCount, .source, .downloaded:
            return true
        case .artist, .album, .dateAdded, .sourceDate, .format, .duration, .serverPlayCount, .year, .bitRate, .bitDepth:
            return false
        }
    }

    /// 节点(或连同子树)的歌的行号,先后与 `index.songIDs(in:scope:)` 相同。目录版分区直接给行号;
    /// 内存版分区(Apple Music 虚拟集合)存的是 id,按 id 换行号(目录里没有的跳过,同内存里查不到)。
    static func rowids(
        in nodeID: LibraryFolderNodeID,
        scope: LibraryFolderSongScope,
        index: LibraryFolderIndex,
        catalog: LibraryCatalog,
        isCancelled: () -> Bool
    ) throws -> [Int32] {
        if let rowids = index.rowids(in: nodeID, scope: scope) { return Array(rowids) }
        let ids = index.songIDs(in: nodeID, scope: scope)
        var result: [Int32] = []
        result.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            if isCancelled() { throw CancellationError() }
            let end = min(ids.count, start + chunkSize)
            result.append(contentsOf: try catalog.rowids(forIDs: Array(ids[start..<end])).compactMap { $0 })
            start = end
        }
        return result
    }

    /// 只带文件夹列(id、标题、曲号、碟号、路径)与所在源的歌,先后同 `rowids`;两步之间删掉的行跳过。
    private static func folderColumnSongs(
        _ rowids: [Int32], sourceID: String, catalog: LibraryCatalog, isCancelled: () -> Bool
    ) throws -> [(rowid: Int32, song: Song)] {
        var result: [(rowid: Int32, song: Song)] = []
        result.reserveCapacity(rowids.count)
        var start = 0
        while start < rowids.count {
            if isCancelled() { throw CancellationError() }
            let end = min(rowids.count, start + chunkSize)
            let chunk = rowids[start..<end]
            let records = try catalog.folderOrderRecords(rowids: chunk)
            for rowid in chunk {
                guard let record = records[rowid] else { continue }
                result.append((rowid, Song(
                    id: record.id, title: record.title, trackNumber: record.trackNumber, discNumber: record.discNumber,
                    fileFormat: .mp3, filePath: record.filePath, sourceID: sourceID, dateAdded: .distantPast
                )))
            }
            start = end
        }
        return result
    }

    /// 整首歌,先后同 `rowids`,每段至多物化上限那么多。
    private static func wholeSongs(
        _ rowids: [Int32], catalog: LibraryCatalog, isCancelled: () -> Bool
    ) throws -> [(rowid: Int32, song: Song)] {
        var result: [(rowid: Int32, song: Song)] = []
        result.reserveCapacity(rowids.count)
        var start = 0
        while start < rowids.count {
            if isCancelled() { throw CancellationError() }
            let end = min(rowids.count, start + chunkSize)
            let chunk = Array(rowids[start..<end])
            let byRowid = try catalog.songsByRowid(chunk)
            for rowid in chunk {
                if let song = byRowid[rowid] { result.append((rowid, song)) }
            }
            start = end
        }
        return result
    }
}
