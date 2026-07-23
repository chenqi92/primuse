import Foundation
import PrimuseKit

/// 重复歌曲清理状态 + 实际执行。原来直接放 DuplicateSongsView 里, view 销毁
/// (用户切到其他菜单再切回来) 进度状态就丢了。提升到 @Observable 服务后,
/// view 只是 progress 的展示窗口, 真实任务不依赖 view 生命周期。
@MainActor
@Observable
final class DuplicateCleanupService {
    struct Progress: Equatable {
        let done: Int
        let total: Int
        /// 上次清理动作结束的最终结果, 让 view 在结束后还能给个 "已清理 N 首"
        /// 的尾巴提示。done == total 后存活若干秒由 view 自行隐藏。
        var isFinished: Bool { done >= total }
    }

    /// 当前进度。nil 表示空闲。
    private(set) var progress: Progress?
    /// 最近一次完成的总数 (= 真正从库里移除的歌曲数), view 用于「已清理 N 首」
    /// 尾巴提示。源端删除失败、仍残留在 NAS/云盘上的歌不计入。
    private(set) var lastCompletedCount: Int = 0
    /// 最近一次清理里源端删除失败、因而保留在库中的歌曲标题。空表示全部成功。
    /// 让 view 能向用户反馈「N 首删除失败」, 同时这些歌不会被 tombstone,
    /// 下次重扫仍可见。
    private(set) var lastFailedTitles: [String] = []
    /// 每次资料库批量删除和结果字段都提交后递增。界面监听它刷新扫描，不能
    /// 监听源文件进度的 100%，因为那一刻资料库事务尚未落地。
    private(set) var completionRevision: UInt = 0

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let sourcesStore: SourcesStore

    private var activeTask: Task<Void, Never>?

    init(library: MusicLibrary, sourceManager: SourceManager, sourcesStore: SourcesStore) {
        self.library = library
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
    }

    /// 串行删除 songs (按源端逐首)。已有任务进行中时忽略再次触发。
    /// 返回的 Task 不需要 await — 调用方只关心 progress 字段。
    @discardableResult
    func cleanup(_ songs: [Song]) -> Task<Void, Never>? {
        guard activeTask == nil, !songs.isEmpty else { return activeTask }
        progress = Progress(done: 0, total: songs.count)

        let task = Task { @MainActor in
            defer {
                // 让 view 看到 100% 再清状态。0.6s 是经验值, 跟 flashAction
                // 的尾巴 banner 错开, 避免两条提示叠在一起。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if self.progress?.isFinished == true {
                        self.progress = nil
                    }
                }
                self.activeTask = nil
            }

            // Sidecar sharing used to scan the complete retained library once
            // for every song being removed. Plan all decisions off-main in one
            // pass before touching the source.
            let librarySnapshot = self.library.songs
            let deletingIDs = Set(songs.map(\.id))
            let sidecarDeletionSongIDs = await Task.detached(priority: .utility) {
                let retainedSongs = librarySnapshot.filter { !deletingIDs.contains($0.id) }
                return SourceManager.sidecarDeletionSongIDs(
                    deleting: songs,
                    retaining: retainedSongs
                )
            }.value

            // 只有源端文件确实被删 (或本就不存在) 的歌才能从库里移除并写
            // tombstone; 删除失败、文件仍在 NAS/云盘上的歌必须保留, 否则它们
            // 会被 tombstone 永久挡掉重扫, 而用户没有恢复入口。
            var removableSongs: [Song] = []
            var failedSongs: [Song] = []
            var failureCount = 0
            var lastProgressPublishAt = Date.distantPast
            let outcomes = await self.sourceManager.deleteSourceFiles(
                for: songs,
                deleteSidecarsForSongIDs: sidecarDeletionSongIDs
            ) { done in
                // A local folder can delete hundreds of tiny files per second.
                // Publishing every counter value made the entire duplicate
                // Form recompute at that rate, so cap UI updates while keeping
                // network-backed (slow) deletions visibly live.
                let now = Date()
                if done == songs.count
                    || done.isMultiple(of: 16)
                    || now.timeIntervalSince(lastProgressPublishAt) >= 0.1 {
                    // `deleteSourceFiles` reaching its total only means the
                    // source-side work is done. Keep one unit pending until
                    // `library.deleteSongs` below has committed the in-memory
                    // library/tombstones. Otherwise the view observes 100%,
                    // rescans the old snapshot, and leaves the just-deleted
                    // duplicate count on screen indefinitely.
                    let committedDone = min(done, max(songs.count - 1, 0))
                    self.progress = Progress(done: committedDone, total: songs.count)
                    lastProgressPublishAt = now
                }
            }

            for outcome in outcomes {
                if outcome.result.hasFailures {
                    failureCount += outcome.result.failedPaths.count
                    failedSongs.append(outcome.song)
                } else {
                    removableSongs.append(outcome.song)
                }
            }

            if failureCount > 0 {
                plog("⚠️ Duplicate cleanup source deletion failures: \(failureCount) (\(failedSongs.count) songs retained in library)")
            }

            // `primuseSongsRemoved` now performs cache cleanup once for this
            // whole batch. The previous path deleted caches per song here and
            // then deleted the same caches again from that notification.
            let remainingCounts = self.library.deleteSongs(removableSongs)
            for (sourceID, remaining) in remainingCounts {
                self.sourcesStore.updateLocal(sourceID) { $0.songCount = remaining }
            }
            self.lastCompletedCount = removableSongs.count
            self.lastFailedTitles = failedSongs.map(\.title)
            self.completionRevision &+= 1

            if outcomes.count < songs.count {
                self.progress = nil
            } else if self.progress?.done != songs.count {
                self.progress = Progress(done: songs.count, total: songs.count)
            }
        }
        activeTask = task
        return task
    }
}
