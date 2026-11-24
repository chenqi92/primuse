import Foundation
import PrimuseKit

/// P2c 的消费方(搜索、歌单导入/镜像/同步、Spotlight、备份、统计……)走目录还是走内存:
/// 目录此刻可读才给读接口;拿不到时调用方保留原来的内存路径(P2 过渡规则)。
@MainActor
enum P2cCatalogAccess {
    static func reader(for library: MusicLibrary) -> LibraryCatalogReader? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        return host.reader
    }
}

/// `LibraryCatalogReader.read` 在 GCD 队列上跑,看不到调用方 Task 的取消;长遍历经它转过去。
final class LibraryCatalogScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

extension LibraryCatalogReader {
    /// `read`,但调用方的 Task 被取消时 `body` 能看到(每批检查一次 `cancellation`)。
    func readCancellable<T: Sendable>(
        _ body: @escaping @Sendable (LibraryCatalog, LibraryCatalogScanCancellation) throws -> T
    ) async throws -> T {
        let cancellation = LibraryCatalogScanCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await read { catalog in try body(catalog, cancellation) }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// 目录本身,给只能同步查的地方(搜索索引按 id 回查)。只在一次操作里用,不要长留。
    func catalogHandle() async throws -> LibraryCatalog {
        try await read { $0 }
    }

    // MARK: - Membership in library order

    /// 一组 id 里在 `scope` 内的歌,按库内顺序(与 `VisibleSongLookup.songs(inLibraryOrder:)` 同序)。
    /// 调用方保证 `ids` 不超过 `LibraryScale.maxMaterializedRows`。
    func songsInLibraryOrder(ids: Set<String>, scope: LibrarySongScope = .visible) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let requested = Array(ids)
        return try await readCancellable { catalog, cancellation in
            var ordered: [(rowid: Int32, song: Song)] = []
            ordered.reserveCapacity(requested.count)
            var start = 0
            while start < requested.count {
                try cancellation.check()
                let end = min(requested.count, start + LibraryScale.maxMaterializedRows)
                let chunk = Array(requested[start..<end])
                var rowidByID: [String: Int32] = [:]
                for (id, rowid) in zip(chunk, try catalog.rowids(forIDs: chunk)) {
                    if let rowid { rowidByID[id] = rowid }
                }
                for song in try catalog.songs(ids: chunk, scope: scope) {
                    if let rowid = rowidByID[song.id] { ordered.append((rowid, song)) }
                }
                start = end
            }
            ordered.sort { $0.rowid < $1.rowid }
            return ordered.map(\.song)
        }
    }

    /// 按 id 取,保持输入顺序;超过物化上限时分批取(调用方的结果本身有界)。
    func songsChunked(ids: [String], scope: LibrarySongScope = .everything) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        return try await readCancellable { catalog, cancellation in
            var result: [Song] = []
            result.reserveCapacity(ids.count)
            var start = 0
            while start < ids.count {
                try cancellation.check()
                let end = min(ids.count, start + LibraryScale.maxMaterializedRows)
                result.append(contentsOf: try catalog.songs(ids: Array(ids[start..<end]), scope: scope))
                start = end
            }
            return result
        }
    }

    /// 这些 id 里目录有的(含停用源,与 `MusicLibrary.storedSong(id:)` 同口径)。只查行号,不物化。
    func existingSongIDs(_ ids: [String]) async throws -> Set<String> {
        let requested = Array(Set(ids))
        guard !requested.isEmpty else { return [] }
        return try await readCancellable { catalog, cancellation in
            var existing = Set<String>()
            var start = 0
            while start < requested.count {
                try cancellation.check()
                let end = min(requested.count, start + LibraryScale.maxMaterializedRows)
                let chunk = Array(requested[start..<end])
                for (id, rowid) in zip(chunk, try catalog.rowids(forIDs: chunk)) where rowid != nil {
                    existing.insert(id)
                }
                start = end
            }
            return existing
        }
    }

    // MARK: - External identity candidates

    /// 歌名主体(`ExternalTrackMatchPolicy.normalizedCoreTitle`)在 `coreTitles` 里的歌,库内顺序。
    /// 与 `PlaylistEntryMatcher(songs:matching:)` 先筛的候选相同:元数据匹配一定同歌名主体,
    /// 所以拿这份候选建的匹配器与拿整库建的给出同样的结果。结果以命中数为界(流式遍历)。
    func songs(matchingCoreTitles coreTitles: Set<String>, scope: LibrarySongScope = .visible) async throws -> [Song] {
        let titles = coreTitles.subtracting([""])
        guard !titles.isEmpty else { return [] }
        return try await readCancellable { catalog, cancellation in
            var result: [Song] = []
            var visited = 0
            try catalog.forEachSong(scope) { _, song in
                visited += 1
                if visited.isMultiple(of: 512), cancellation.isCancelled { return false }
                let matches = autoreleasepool {
                    titles.contains(ExternalTrackMatchPolicy.normalizedCoreTitle(song.title))
                }
                if matches { result.append(song) }
                return true
            }
            try cancellation.check()
            return result
        }
    }

    /// 某个源里按路径算出的键(服务端条目 id 等)→ 第一首这样的歌的 id,只收 `wanted` 里的;
    /// `wanted` 为 nil 时整源都收。库内顺序,先到的算数(与按 `library.songs` 走一遍的结果相同)。
    /// 只读身份投影(行号、id、路径),不物化整首歌。
    func firstSongIDs(
        sourceID: String,
        wanting wanted: Set<String>?,
        key: @escaping @Sendable (String) -> String?
    ) async throws -> [String: String] {
        if let wanted, wanted.isEmpty { return [:] }
        return try await readCancellable { catalog, cancellation in
            var result: [String: String] = [:]
            var visited = 0
            try catalog.forEachSongIdentity(.source(sourceID)) { _, id, filePath in
                visited += 1
                if visited.isMultiple(of: 1_024), cancellation.isCancelled { return false }
                guard let value = key(filePath), result[value] == nil else { return true }
                if let wanted {
                    guard wanted.contains(value) else { return true }
                    result[value] = id
                    return result.count < wanted.count
                }
                result[value] = id
                return true
            }
            try cancellation.check()
            return result
        }
    }

    /// 服务端歌单曲目 id → 本地歌曲 id(`ServerPlaylistIdentity.serverItemID(fromFilePath:)`)。
    func serverItemIndex(sourceID: String, wanting wanted: Set<String>?) async throws -> [String: String] {
        try await firstSongIDs(sourceID: sourceID, wanting: wanted) {
            ServerPlaylistIdentity.serverItemID(fromFilePath: $0)
        }
    }

    // MARK: - Spotlight

    /// Spotlight 收录的歌,与 `SpotlightIndexService.indexedSongs(of:)` 同一挑法:先是最近放过、喜欢的
    /// (按 `prioritySongIDs` 的先后,只要可见的,去重),再按加入时间从新到旧(同一时刻按 id 升序)
    /// 补到 `limit`。结果以 `limit` 为界;另给可见歌曲总数(「超出上限」提示用)。
    func spotlightSongSelection(prioritySongIDs: [String], limit limitCap: Int) async throws -> LibraryCatalogSpotlightSelection {
        try await readCancellable { (catalog, cancellation) -> LibraryCatalogSpotlightSelection in
            let visibleCount = try catalog.songCount(.visible)
            let limit = min(visibleCount, limitCap)
            var chosen: [Song] = []
            chosen.reserveCapacity(limit)
            var chosenIDs = Set<String>()
            var orderedPriority: [String] = []
            var seenPriority = Set<String>()
            for id in prioritySongIDs where seenPriority.insert(id).inserted { orderedPriority.append(id) }
            var start = 0
            while start < orderedPriority.count, chosen.count < limit {
                try cancellation.check()
                let end = min(orderedPriority.count, start + LibraryScale.maxMaterializedRows)
                for song in try catalog.songs(ids: Array(orderedPriority[start..<end]), scope: .visible)
                where chosen.count < limit && chosenIDs.insert(song.id).inserted {
                    chosen.append(song)
                }
                start = end
            }
            let priorityCount = chosen.count
            let needed = limit - chosen.count
            guard needed > 0 else {
                return LibraryCatalogSpotlightSelection(songs: chosen, priorityCount: priorityCount, visibleCount: visibleCount)
            }
            // 目录按加入时间降序、同一时刻按行号降序给;够数后把同一时刻的都收进来,再按 id 定先后。
            let rowids = try catalog.songRowList(order: .dateAdded, scope: .visible).rowids
            var newest: [Song] = []
            newest.reserveCapacity(needed)
            var cursor = 0
            scan: while cursor < rowids.count {
                try cancellation.check()
                let end = min(rowids.count, cursor + LibraryScale.importBatchSize)
                for song in try catalog.songs(rowids: rowids[cursor..<end]) where !chosenIDs.contains(song.id) {
                    if newest.count >= needed, let last = newest.last, song.dateAdded != last.dateAdded { break scan }
                    newest.append(song)
                }
                cursor = end
            }
            newest.sort { lhs, rhs in
                lhs.dateAdded != rhs.dateAdded ? lhs.dateAdded > rhs.dateAdded : lhs.id < rhs.id
            }
            chosen.append(contentsOf: newest.prefix(needed))
            return LibraryCatalogSpotlightSelection(songs: chosen, priorityCount: priorityCount, visibleCount: visibleCount)
        }
    }
}

/// `LibraryCatalogReader.spotlightSongSelection` 的结果:前 `priorityCount` 首是优先的。
struct LibraryCatalogSpotlightSelection: Sendable {
    let songs: [Song]
    let priorityCount: Int
    let visibleCount: Int
}
