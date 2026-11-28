import Foundation
import PrimuseKit

/// 首页会摆出来的那几个文件夹（钉住的、各源根目录和它们前几个子目录）先挑好封面:每个文件夹按文件夹里的先后取前四首
/// 有封面的歌。在主线程外做：源的根目录就是整个源，挑满四张就停，不先展开整棵子树。
/// 歌曲模型在内存里时按可见歌的查表判断(与以前相同);不在内存里时(6c 单元 4 U3c)同一组文件夹、同一条规则问曲库目录
/// (`LibraryFolderIndex.firstSongIDsWithCover`,一段一条查询),挑出的相同,挑中的歌按 id 一次取出。
enum HomeFolderCoverPrewarm {
    struct Pins: Sendable {
        let raw: String
        let displayCount: Int

        static func current() -> Pins {
            Pins(
                raw: UserDefaults.standard.string(forKey: HomeFolderPinStorage.key) ?? "",
                displayCount: UserDefaults.standard.object(forKey: HomeFolderPinStorage.displayCountKey) as? Int
                    ?? HomeFolderPinStorage.defaultDisplayCount
            )
        }
    }

    struct Covers: Sendable {
        // crash-pattern: allow library-array-property 预挑的封面歌,至多候选文件夹数 × 4 首(从 HomeDiscoveryModel 移来)
        let songsByID: [String: Song]
        let covers: [LibraryFolderNodeID: [String]]
        let pinnedNodeIDs: Set<LibraryFolderNodeID>

        static let none = Covers(songsByID: [:], covers: [:], pinnedNodeIDs: [])
    }

    /// 模型在内存里用 `lookup`;不在时用 `catalog`。目录答不了(没有可读的目录、读失败)时一张都不预挑:
    /// 卡片显示时在后台补(`HomeDiscoveryModel.coverSongs(for:)`),不在主线程上逐首读。
    static func covers(
        for index: LibraryFolderIndex,
        lookup: VisibleSongLookup?,
        catalog: LibraryCatalog?,
        pins: Pins,
        isCancelled: () -> Bool
    ) -> Covers {
        if let lookup { return fromMemory(index, lookup: lookup, pins: pins, isCancelled: isCancelled) }
        guard let catalog else { return .none }
        return fromCatalog(index, catalog: catalog, pins: pins, isCancelled: isCancelled) ?? .none
    }

    /// 要预挑的文件夹:钉住的、各源根目录和它们前 16 个子目录。
    static func candidates(in index: LibraryFolderIndex, pins: Pins) -> Set<LibraryFolderNodeID> {
        var candidateNodeIDs = Set(
            HomeFolderPinStorage.resolvedPins(pins.raw, index: index, defaultCount: pins.displayCount)
        )
        for rootNode in LibraryFolderBrowsePolicy.rootNodes(in: index, sourceID: nil) {
            candidateNodeIDs.insert(rootNode.id)
            for child in LibraryFolderBrowsePolicy.displayedChildren(in: index, of: rootNode.id).prefix(16) {
                candidateNodeIDs.insert(child.id)
            }
        }
        return candidateNodeIDs
    }

    /// 模型在内存里:按可见歌的查表判断有没有封面。
    static func fromMemory(
        _ index: LibraryFolderIndex, lookup: VisibleSongLookup, pins: Pins, isCancelled: () -> Bool
    ) -> Covers {
        let candidateNodeIDs = candidates(in: index, pins: pins)
        var songsByID: [String: Song] = [:]
        var covers: [LibraryFolderNodeID: [String]] = [:]
        for nodeID in candidateNodeIDs {
            if isCancelled() { break }
            let ids = index.firstSongIDs(
                in: nodeID,
                limit: 4,
                where: { lookup.song(id: $0)?.coverArtFileName != nil },
                isCancelled: isCancelled
            )
            for songID in ids where songsByID[songID] == nil {
                songsByID[songID] = lookup.song(id: songID)
            }
            covers[nodeID] = ids
        }
        return Covers(songsByID: songsByID, covers: covers, pinnedNodeIDs: candidateNodeIDs)
    }

    /// 模型不在内存里:同一组文件夹按段问目录。nil:目录读失败(答不了,不当没有封面)。
    static func fromCatalog(
        _ index: LibraryFolderIndex, catalog: LibraryCatalog, pins: Pins, isCancelled: () -> Bool
    ) -> Covers? {
        let candidateNodeIDs = candidates(in: index, pins: pins)
        guard let picked = picks(Array(candidateNodeIDs), in: index, catalog: catalog, isCancelled: isCancelled) else { return nil }
        var songsByID: [String: Song] = [:]
        for songs in picked.values {
            for song in songs { songsByID[song.id] = song }
        }
        return Covers(songsByID: songsByID, covers: picked.mapValues { $0.map(\.id) }, pinnedNodeIDs: candidateNodeIDs)
    }

    /// 这几个文件夹各自的封面歌(先后同文件夹里),歌按 id 从目录取(可见的;至多文件夹数 × 4 首)。
    /// 挑中而已经不可见的歌不在里面,同内存里查表查不到的那几首。nil:目录读失败。
    static func picks(
        _ nodeIDs: [LibraryFolderNodeID], in index: LibraryFolderIndex, catalog: LibraryCatalog, isCancelled: () -> Bool
    ) -> [LibraryFolderNodeID: [Song]]? {
        do {
            var ids: [LibraryFolderNodeID: [String]] = [:]
            for nodeID in nodeIDs {
                if isCancelled() { break }
                ids[nodeID] = try index.firstSongIDsWithCover(in: nodeID, limit: 4, catalog: catalog, isCancelled: isCancelled)
            }
            let wanted = Array(Set(ids.values.joined()))
            var songsByID: [String: Song] = [:]
            for start in stride(from: 0, to: wanted.count, by: LibraryScale.maxMaterializedRows) {
                let chunk = Array(wanted[start..<min(wanted.count, start + LibraryScale.maxMaterializedRows)])
                for song in try catalog.songs(ids: chunk, scope: .visible) { songsByID[song.id] = song }
            }
            return ids.mapValues { $0.compactMap { songsByID[$0] } }
        } catch {
            plog("⚠️ Home folder covers from the catalog failed: \(error)")
            return nil
        }
    }
}

/// 模型不在内存里时,卡片要画而没预挑过的文件夹(打开的文件夹里的子目录、收藏的深层目录)排队在后台挑:同一拍里画出来的
/// 一起成一批,一批一个后台任务,挑好交回模型(`adoptCatalogCovers`,一批重画一次)。同一份索引里每个文件夹只排一次;
/// 目录答不了的这一批不再重试,卡片照旧画文件夹图标,索引换了(重建、目录变了)再挑。
@MainActor
final class HomeFolderCatalogCoverQueue {
    private var requested: Set<LibraryFolderNodeID> = []
    private var pending: [LibraryFolderNodeID] = []
    /// 排队时的那份索引(不替模型留着换下来的索引)。
    private weak var index: LibraryFolderIndex?
    private var worker: Task<Void, Never>?

    init() {}
}

extension HomeFolderCatalogCoverQueue {
    func request(
        _ nodeID: LibraryFolderNodeID, in index: LibraryFolderIndex, library: MusicLibrary, model: HomeDiscoveryModel
    ) {
        if self.index !== index {
            worker?.cancel()
            worker = nil
            requested = []
            pending = []
            self.index = index
        }
        guard requested.insert(nodeID).inserted else { return }
        pending.append(nodeID)
        guard worker == nil else { return }
        worker = Task { [weak self, weak model, weak library] in
            // 等这一拍的卡片都排进来。
            await Task.yield()
            while let self, let model, let library, !Task.isCancelled, self.index === index, !self.pending.isEmpty {
                let batch = self.pending
                self.pending = []
                guard let catalog = library.catalogHost?.mirror.readableCatalog else { break }
                let picked = await Task.detached(priority: .utility) {
                    HomeFolderCoverPrewarm.picks(batch, in: index, catalog: catalog) { false }
                }.value
                guard !Task.isCancelled, self.index === index else { return }
                if let picked { model.adoptCatalogCovers(picked, for: index) }
            }
            if let self, self.index === index { self.worker = nil }
        }
    }
}
