import Foundation
import Observation
import PrimuseKit

/// 文件夹页「重新读取文件标签」的进度。iPhone 文件夹页与 Mac 内嵌文件夹浏览各持一份，
/// 离开页面就随页面释放；读取本身在回填服务里继续跑完。
///
/// 原来在 SongListView.swift 里;6c 单元 4 U9b 移到这里(方法挪进扩展),加上歌曲模型不在内存里时的判断:
/// 「能不能读」与「读哪些」按 id 逐首问资料库(`canRereadTags(songID:expectedSourceID:)`,放掉时每问一次就在主线程上
/// 读一次目录 —— 菜单里 24 首、点下去整个文件夹)改成在主线程外按段从曲库目录取歌,在主线程上照同一条规则判断。
@MainActor
@Observable
final class LibraryFolderMaintenanceModel {
    private(set) var rereadProgress: MetadataTagRereadProgress?
    private(set) var isRereading = false
    @ObservationIgnored private var rereadTask: Task<Void, Never>?
    /// 模型不在内存里时「前几首里有没有能读的」的答案,按问的那几首与源记。
    private(set) var rereadProbe: RereadProbe?
    /// 正在后台判断的那几首(同一组只判断一次;菜单每次求值都会问)。
    @ObservationIgnored private var probingIDs: [String]?
    @ObservationIgnored private var rereadProbeTask: Task<Void, Never>?

    init() {}
}

extension LibraryFolderMaintenanceModel {
    struct RereadProbe: Equatable {
        let ids: [String]
        let sourceID: String
        let answer: Bool
    }

    func rereadTags(songIDs: [String], sourceID: String, backfill: MetadataBackfillService, library: MusicLibrary) {
        guard library.isReady else { return rereadTagsFromCatalog(songIDs: songIDs, sourceID: sourceID, backfill: backfill, library: library) }
        let readable = songIDs.filter { backfill.canRereadTags(songID: $0, expectedSourceID: sourceID) }
        guard rereadTask == nil, !readable.isEmpty else { return }
        isRereading = true
        rereadProgress = MetadataTagRereadProgress(total: readable.count)
        rereadTask = Task { @MainActor [weak self] in
            let result = await backfill.rereadTags(songIDs: readable, expectedSourceID: sourceID) { progress in
                self?.rereadProgress = progress
            }
            self?.rereadProgress = result
            self?.isRereading = false
            self?.rereadTask = nil
        }
    }

    /// 只看前几首判断能不能读。模型在内存里照原来当场问(`asksLoaded`,即 `canRereadTags(songID:expectedSourceID:)`);
    /// 放掉了时先答「不能」(菜单里先不出现这一项),在后台取好歌、照 `readable`(`canRereadTags(for:)`)判断好再答 ——
    /// 不在菜单每次求值时逐首读目录。
    func canReread(
        _ ids: ArraySlice<String>, sourceID: String, library: MusicLibrary,
        asksLoaded: (String) -> Bool, readable: @escaping @MainActor (Song) -> Bool
    ) -> Bool {
        if library.isReady { return ids.contains(where: asksLoaded) }
        let asked = Array(ids)
        if let rereadProbe, rereadProbe.ids == asked, rereadProbe.sourceID == sourceID { return rereadProbe.answer }
        if probingIDs != asked + [sourceID] {
            probingIDs = asked + [sourceID]
            rereadProbeTask?.cancel()
            rereadProbeTask = Task { @MainActor [weak self] in
                let found = await Self.rereadable(asked, sourceID: sourceID, library: library, readable: readable)
                guard !Task.isCancelled, let self else { return }
                self.probingIDs = nil
                // 答不了:先不给这一项(下次求值再问)。
                guard let found else { return }
                self.rereadProbe = RereadProbe(ids: asked, sourceID: sourceID, answer: !found.isEmpty)
            }
        }
        return false
    }

    /// 模型不在内存里:读哪些在主线程外挑好再读;挑不出来(目录答不了)就不读,也不显示「读完了 0 首」。
    private func rereadTagsFromCatalog(
        songIDs: [String], sourceID: String, backfill: MetadataBackfillService, library: MusicLibrary
    ) {
        guard rereadTask == nil else { return }
        isRereading = true
        rereadTask = Task { @MainActor [weak self] in
            guard let readable = await Self.rereadable(
                songIDs, sourceID: sourceID, library: library, readable: { backfill.canRereadTags(for: $0) }
            ), !readable.isEmpty, let self else {
                self?.isRereading = false
                self?.rereadTask = nil
                return
            }
            self.rereadProgress = MetadataTagRereadProgress(total: readable.count)
            let result = await backfill.rereadTags(songIDs: readable, expectedSourceID: sourceID) { [weak self] progress in
                self?.rereadProgress = progress
            }
            self.rereadProgress = result
            self.isRereading = false
            self.rereadTask = nil
        }
    }

    /// 这些 id 里能重新读取标签的,先后不变:歌在主线程外按段从曲库目录取(含停用的源,同 `library.song(id:)`;
    /// 每段至多物化上限),在主线程上照 `canRereadTags(songID:expectedSourceID:)` 的规则判断(只看源与文件类型,
    /// 不再读目录)。nil = 答不了。
    static func rereadable(
        _ ids: [String], sourceID: String, library: MusicLibrary, readable isReadable: @MainActor (Song) -> Bool
    ) async -> [String]? {
        guard !ids.isEmpty else { return [] }
        guard let reader = library.readableCatalogReader else { return nil }
        var readable: [String] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + LibraryScale.maxMaterializedRows)])
            let songs: [Song]
            do {
                songs = try await reader.read { try $0.songs(ids: chunk, scope: .everything) }
            } catch {
                plog("⚠️ Folder tag re-read songs from the catalog failed: \(error)")
                return nil
            }
            readable += songs.filter { $0.sourceID == sourceID && isReadable($0) }.map(\.id)
            start += chunk.count
        }
        return readable
    }
}

/// 文件夹页「⋯」里的「增量扫描此目录」与「重新读取文件标签」。服务由页面在自己的视图
/// 层级里取好再交进来：导航栏菜单的宿主拿不到环境（见 `FolderPlaylistMenuButton`）。
@MainActor
struct LibraryFolderMaintenanceActions {
    var rescan: (() -> Void)?
    var rereadTags: (() -> Void)?
    var isRereading = false

    static func make(
        nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex?,
        songIDs: [String],
        model: LibraryFolderMaintenanceModel,
        scanService: ScanService,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary,
        scraperService: MusicScraperService,
        backfill: MetadataBackfillService
    ) -> LibraryFolderMaintenanceActions? {
        guard nodeID.kind == .folder || nodeID.kind == .scanRoot,
              let source = sourcesStore.source(id: nodeID.sourceID),
              source.isEnabled, !source.isDeleted else { return nil }
        var actions = LibraryFolderMaintenanceActions(isRereading: model.isRereading)
        if ScanService.supportsFolderRescan(source),
           let index,
           let anchor = LibraryFolderRescanAnchor.make(for: nodeID, in: index) {
            actions.rescan = {
                _ = scanService.rescanFolder(
                    of: source,
                    request: SourceFolderRescanRequest(
                        anchorSongID: anchor.songID,
                        levelsAbove: anchor.levelsAbove
                    ),
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourcesStore,
                    scraperService: scraperService
                )
            }
        }
        // 只看前几首判断能不能读：整个文件夹逐首过一遍留到点下去的时候。
        if model.canReread(
            songIDs.prefix(24), sourceID: source.id, library: library,
            asksLoaded: { backfill.canRereadTags(songID: $0, expectedSourceID: source.id) },
            readable: { backfill.canRereadTags(for: $0) }
        ) {
            actions.rereadTags = {
                model.rereadTags(songIDs: songIDs, sourceID: source.id, backfill: backfill, library: library)
            }
        }
        return actions.rescan == nil && actions.rereadTags == nil ? nil : actions
    }
}
