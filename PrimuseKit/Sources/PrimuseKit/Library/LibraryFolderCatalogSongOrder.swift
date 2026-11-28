import Foundation

/// 「目录」页(首页目录区、目录页)一个文件夹里歌的先后,在曲库目录上排(6c 单元 4 U9a)。歌曲模型不在内存里时用,
/// 与模型在内存里时 `LibraryFolderBrowsePolicy.sortedSongs(_:order:spokenWordSongIDs:)` 对同一批歌给出的相同:
/// 交给的是同一个排序函数,输入的先后相同,每首歌在它读到的列上与内存里的相同。
///
/// - 曲目顺序(整夹有声除外)、原文件名、标题、标题语言优先只读 id、标题、曲号、碟号、路径和所在源:按行号分段取这几列
///   (`folderOrderRecords`,建索引时排一个目录用的同一条查询),拼成只带这几列的歌,不物化整首歌。
/// - 按艺人、专辑、加入时间、来源日期、格式排,和整夹都是有声(按书架的章节顺序)时要整首歌:`songLimit` 首以内
///   按行号分段物化;超过时返回 nil,调用方占用歌曲模型照内存排。
/// - 目录读失败时抛出(调用方当「答不了」,不当成空文件夹);`isCancelled` 为真时抛 `CancellationError`。
///
/// 代价:每段一条按行号的 `IN` 查询(段长 `chunkSize`),只带几列时每首约几百字节,排完即放;排序本身与内存里相同。
public enum LibraryFolderCatalogSongOrder {
    /// 排哪些歌:页面上这个文件夹自己列出的(`LibraryFolderBrowsePolicy.displayedSongIDs`),
    /// 或整棵子树(「播放」整个文件夹,`songIDs(in:scope: .descendants)`)。
    public enum Scope: Sendable {
        case displayed
        case descendants
    }

    /// 排好的歌:id 与行号一一对应(行号给按页物化行用)。
    public struct Ordered: Sendable, Equatable {
        public let ids: [String]
        public let rowids: ContiguousArray<Int32>
    }

    /// 每段取多少行。与物化上限相同:一段一个读事务,不长时间占着一个读快照。
    static let chunkSize = LibraryScale.maxMaterializedRows

    public static func ordered(
        in nodeID: LibraryFolderNodeID,
        scope: Scope,
        index: LibraryFolderIndex,
        order: HomeFolderSongOrder,
        spokenWordSongIDs: Set<String>,
        catalog: LibraryCatalog,
        songLimit: Int = LibraryScale.maxMaterializedRows,
        isCancelled: () -> Bool = { false }
    ) throws -> Ordered? {
        let rowids = try self.rowids(in: nodeID, scope: scope, index: index, catalog: catalog, isCancelled: isCancelled)
        var entries: [(rowid: Int32, song: Song)]
        if readsFolderColumnsOnly(order) {
            entries = try folderColumnSongs(rowids, sourceID: nodeID.sourceID, catalog: catalog, isCancelled: isCancelled)
            // 整夹都是有声:内存里按书架的章节顺序排(`LibraryFolderTrackOrder.shelfOrderedIDs`),那要整首歌。
            if case .trackOrder = order, entries.count > 1, !spokenWordSongIDs.isEmpty,
               entries.allSatisfy({ spokenWordSongIDs.contains($0.song.id) }) {
                guard rowids.count <= songLimit else { return nil }
                entries = try wholeSongs(rowids, catalog: catalog, isCancelled: isCancelled)
            }
        } else {
            guard rowids.count <= songLimit else { return nil }
            entries = try wholeSongs(rowids, catalog: catalog, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        guard entries.count > 1 else {
            return Ordered(ids: entries.map(\.song.id), rowids: ContiguousArray(entries.map(\.rowid)))
        }
        let rowidByID = Dictionary(entries.map { ($0.song.id, $0.rowid) }, uniquingKeysWith: { first, _ in first })
        let sorted = LibraryFolderBrowsePolicy.sortedSongs(
            entries.map(\.song), order: order, spokenWordSongIDs: spokenWordSongIDs
        )
        var ids: [String] = []
        var orderedRowids = ContiguousArray<Int32>()
        ids.reserveCapacity(sorted.count)
        orderedRowids.reserveCapacity(sorted.count)
        for song in sorted {
            guard let rowid = rowidByID[song.id] else { continue }
            ids.append(song.id)
            orderedRowids.append(rowid)
        }
        return Ordered(ids: ids, rowids: orderedRowids)
    }

    /// 节点(或连同子树)的歌的 id,先后同 `LibraryFolderIndex.songIDs(in:scope:)`;不同的是目录读失败时抛出,
    /// 不当成没有歌 —— 下载整个文件夹、专辑元数据这类操作要分得清「答不了」与「没有」。内存版分区不读目录。
    public static func songIDs(
        in nodeID: LibraryFolderNodeID,
        scope: LibraryFolderSongScope,
        index: LibraryFolderIndex,
        catalog: LibraryCatalog,
        isCancelled: () -> Bool = { false }
    ) throws -> [String] {
        guard index.isCatalogBacked(sourceID: nodeID.sourceID), let rowids = index.rowids(in: nodeID, scope: scope) else {
            return index.songIDs(in: nodeID, scope: scope)
        }
        var ids: [String] = []
        ids.reserveCapacity(rowids.count)
        var start = rowids.startIndex
        while start < rowids.endIndex {
            if isCancelled() { throw CancellationError() }
            let end = min(rowids.endIndex, start + chunkSize)
            ids.append(contentsOf: try catalog.songIDs(rowids: rowids[start..<end]))
            start = end
        }
        return ids
    }

    /// 排序函数只读到 id、标题、曲号、碟号、路径、所在源的顺序(见各比较器:`LibraryFolderTrackOrder`、
    /// `AlbumTrackOrder`、原文件名、`SongListSnapshotBuilder` 的标题比较)。
    static func readsFolderColumnsOnly(_ order: HomeFolderSongOrder) -> Bool {
        switch order {
        case .trackOrder, .originalName, .titleLanguageFirst:
            return true
        case .sorted(let listOrder):
            return listOrder.criterion == .title
        }
    }

    /// 要排的歌的行号,先后与内存里那份 id 相同。目录版分区直接给行号;内存版分区(Apple Music 虚拟集合)存的是 id,
    /// 按 id 换行号(目录里没有的跳过,同内存里查不到)。
    static func rowids(
        in nodeID: LibraryFolderNodeID,
        scope: Scope,
        index: LibraryFolderIndex,
        catalog: LibraryCatalog,
        isCancelled: () -> Bool
    ) throws -> [Int32] {
        if index.isCatalogBacked(sourceID: nodeID.sourceID) {
            switch scope {
            case .displayed: return Array(displayedRowids(in: index, of: nodeID))
            case .descendants: return Array(index.rowids(in: nodeID, scope: .descendants) ?? [])
            }
        }
        let ids = scope == .displayed
            ? LibraryFolderBrowsePolicy.displayedSongIDs(in: index, of: nodeID)
            : index.songIDs(in: nodeID, scope: .descendants)
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

    /// 同 `LibraryFolderBrowsePolicy.displayedSongIDs`,给行号:源节点把唯一的扫描根、「未分类」「其他」里直接的歌并进来。
    static func displayedRowids(in index: LibraryFolderIndex, of nodeID: LibraryFolderNodeID) -> ContiguousArray<Int32> {
        var result = index.rowids(in: nodeID, scope: .direct) ?? []
        guard nodeID.kind == .source else { return result }
        let root = LibraryFolderBrowsePolicy.collapsedScanRoot(in: index, for: nodeID)
        for child in index.children(of: nodeID)
        where child.id == root?.id || child.kind == .other || child.kind == .uncategorized {
            result.append(contentsOf: index.rowids(in: child.id, scope: .direct) ?? [])
        }
        return result
    }

    /// 只带排序要的几列的歌,先后同 `rowids`;两步之间删掉的行跳过(同内存里查不到)。
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
