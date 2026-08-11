import Foundation
import PrimuseKit

/// 批量删歌的编排。两种语义共用一条提交路径：
///
/// - `.libraryOnly` 只丢库记录（会写 tombstone，重扫不会再回来），实体文件
///   原样留在源上；
/// - `.sourceFiles` 先删源端文件，且**只有**确实删掉（或本就不存在）的那些
///   才允许从库里移除并 tombstone。删失败的必须留在库中 —— 否则它们会被
///   tombstone 永久挡住重扫，而用户没有恢复入口。这条安全约定与
///   `DuplicateCleanupService` 一致。
@MainActor
@Observable
final class SongBatchRemovalService {
    enum Mode: Equatable, Sendable {
        case libraryOnly
        case sourceFiles
    }

    struct Progress: Equatable {
        let done: Int
        let total: Int
        var isFinished: Bool { done >= total }
    }

    struct Outcome: Equatable {
        let mode: Mode
        /// 真正从库里移除的数量。
        let removed: Int
        /// 源端删除失败、因而保留在库中的数量。
        let failed: Int
        /// 调用方在发起前就排除掉的数量（源类型不支持删除等）。
        let skipped: Int
    }

    /// nil 表示空闲。
    private(set) var progress: Progress?
    private(set) var lastOutcome: Outcome?
    /// 每完成一次批量删除递增。界面监听它弹结果提示，而不是监听进度的 100% ——
    /// 那一刻资料库事务尚未提交。
    private(set) var completionRevision: UInt = 0

    var isBusy: Bool { activeTask != nil }

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let sourcesStore: SourcesStore
    private let player: AudioPlayerService

    private var activeTask: Task<Void, Never>?

    init(
        library: MusicLibrary,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        player: AudioPlayerService
    ) {
        self.library = library
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.player = player
    }

    /// 已有任务进行中时忽略再次触发。调用方不需要 await，只关心 `progress`
    /// 和 `completionRevision`。
    @discardableResult
    func remove(_ songs: [Song], mode: Mode, skipped: Int = 0) -> Task<Void, Never>? {
        guard activeTask == nil, !songs.isEmpty else { return nil }
        progress = Progress(done: 0, total: songs.count)

        let task = Task { @MainActor in
            defer {
                // 让界面看到 100% 再清状态，跟结果提示错开。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if self.progress?.isFinished == true {
                        self.progress = nil
                    }
                }
                self.activeTask = nil
            }

            await self.player.prepareQueueForRemovingSongs(
                withIDs: Set(songs.map(\.id))
            )

            switch mode {
            case .libraryOnly:
                self.commit(removable: songs, failed: [], mode: mode, skipped: skipped)
            case .sourceFiles:
                await self.deleteSourceFiles(songs, skipped: skipped)
            }
            self.progress = Progress(done: songs.count, total: songs.count)
        }
        activeTask = task
        return task
    }

    /// 按源类型把待删列表分成「能删源文件」和「只能留着」两拨，让确认弹窗
    /// 能提前把数字摊给用户看，而不是删完才说有几首没删掉。
    nonisolated static func partitionForSourceDeletion(
        _ songs: [Song],
        sourceTypesByID: [String: MusicSourceType]
    ) -> (deletable: [Song], skipped: [Song]) {
        var deletable: [Song] = []
        var skipped: [Song] = []
        for song in songs {
            if SourceFileDeletionPolicy.shouldShowDeleteAction(for: sourceTypesByID[song.sourceID]) {
                deletable.append(song)
            } else {
                skipped.append(song)
            }
        }
        return (deletable, skipped)
    }

    private func deleteSourceFiles(_ songs: [Song], skipped: Int) async {
        // Sidecar 共享判定一次算完。逐首扫描整个保留库会让删 200 首变成
        // O(200 × 库大小) 的主线程开销。
        let librarySnapshot = library.songs
        let deletingIDs = Set(songs.map(\.id))
        let sidecarDeletionSongIDs = await Task.detached(priority: .utility) {
            let retained = librarySnapshot.filter { !deletingIDs.contains($0.id) }
            return SourceManager.sidecarDeletionSongIDs(deleting: songs, retaining: retained)
        }.value

        var lastPublishAt = Date.distantPast
        let outcomes = await sourceManager.deleteSourceFiles(
            for: songs,
            deleteSidecarsForSongIDs: sidecarDeletionSongIDs
        ) { done in
            // 本地源能每秒删掉上百个小文件，逐格发布会让整屏按那个频率重算。
            let now = Date()
            guard done == songs.count
                    || done.isMultiple(of: 16)
                    || now.timeIntervalSince(lastPublishAt) >= 0.1
            else { return }
            // 源端删完不等于事务落地，留一格给下面的 `library.deleteSongs`。
            self.progress = Progress(
                done: min(done, max(songs.count - 1, 0)),
                total: songs.count
            )
            lastPublishAt = now
        }

        var removable: [Song] = []
        var failed: [Song] = []
        for outcome in outcomes {
            if outcome.result.shouldRemoveLibraryRecord {
                removable.append(outcome.song)
            } else {
                failed.append(outcome.song)
            }
        }

        commit(removable: removable, failed: failed, mode: .sourceFiles, skipped: skipped)
    }

    private func commit(removable: [Song], failed: [Song], mode: Mode, skipped: Int) {
        if !removable.isEmpty {
            let remainingCounts = library.deleteSongs(removable)
            for (sourceID, remaining) in remainingCounts {
                sourcesStore.updateLocal(sourceID) { $0.songCount = remaining }
            }
        }
        if !failed.isEmpty {
            plog("⚠️ Batch removal kept \(failed.count) songs in library (source deletion failed)")
        }
        lastOutcome = Outcome(
            mode: mode,
            removed: removable.count,
            failed: failed.count,
            skipped: skipped
        )
        completionRevision &+= 1
    }

}
