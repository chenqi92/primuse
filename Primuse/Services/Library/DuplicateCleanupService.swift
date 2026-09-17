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

    struct SourceFailure: Identifiable {
        let source: MusicSource
        var songs: [Song]
        var reasons: Set<SourceFileDeletionFailureReason>
        /// Per-song reasons. `reasons` is the union used for the help text; the
        /// device-local removal offer has to be decided song by song so a
        /// timed-out row in the same batch is never swept along.
        var reasonsBySongID: [String: Set<SourceFileDeletionFailureReason>] = [:]
        /// First server message recorded per song, kept for the ledger entry.
        var messagesBySongID: [String: String] = [:]
        var id: String { source.id }

        /// Songs of this failure that may be removed from this device only:
        /// every recorded reason for that song is a refusal the source will
        /// keep giving. `removeSongsFromThisDevice` records both exclusion-key
        /// shapes (account-identity prefix and raw source ID), so account-typed
        /// sources are covered as well as path-typed ones.
        var deviceLocalRemovableSongs: [Song] {
            songs.filter { song in
                SongLocalRemovalPolicy.canResolveLocally(
                    failureReasons: reasonsBySongID[song.id] ?? []
                )
            }
        }

        var supportsDeviceLocalRemoval: Bool { !deviceLocalRemovableSongs.isEmpty }

        /// Keep only the songs still relevant to this failure and drop the
        /// per-song reasons that went with the removed ones, so the union used
        /// for the help text never outlives its songs.
        mutating func retainSongs(where isIncluded: (Song) -> Bool) {
            songs.removeAll { !isIncluded($0) }
            let keptIDs = Set(songs.map(\.id))
            messagesBySongID = messagesBySongID.filter { keptIDs.contains($0.key) }
            guard !reasonsBySongID.isEmpty else { return }
            reasonsBySongID = reasonsBySongID.filter { keptIDs.contains($0.key) }
            reasons = Set(reasonsBySongID.values.joined())
        }
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
    private(set) var lastSourceFailures: [SourceFailure] = []
    /// 每次资料库批量删除和结果字段都提交后递增。界面监听它刷新扫描，不能
    /// 监听源文件进度的 100%，因为那一刻资料库事务尚未落地。
    private(set) var completionRevision: UInt = 0
    /// 设备本地移除 (不动源端) 后递增。界面监听它刷新重复分组, 让被隐藏的行
    /// 立即消失, 而不会触发 completionRevision 的「已清理 N 首」结果提示。
    private(set) var deviceLocalRemovalRevision = 0

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let sourcesStore: SourcesStore

    private var activeTask: Task<Void, Never>?

    init(library: MusicLibrary, sourceManager: SourceManager, sourcesStore: SourcesStore) {
        self.library = library
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
    }

    @discardableResult
    func retryFailedSource(_ sourceID: String) -> Task<Void, Never>? {
        let failedIDs = Set(lastSourceFailures.filter { $0.id == sourceID }.flatMap { $0.songs.map(\.id) })
        return cleanup(library.songs.filter { failedIDs.contains($0.id) && $0.sourceID == sourceID })
    }

    /// Songs of `sourceID` that the user may drop from this device's library
    /// while the server copy stays in place. Empty unless the deletion was
    /// refused for a reason a retry cannot fix.
    func deviceLocalRemovableSongs(forSourceID sourceID: String) -> [Song] {
        lastSourceFailures
            .first { $0.id == sourceID }?
            .deviceLocalRemovableSongs ?? []
    }

    /// Remove only the local rows after a permission refusal. The catalogue
    /// retained for synchronization leaves other devices unchanged.
    @discardableResult
    func removeFromThisDeviceOnly(sourceID: String) throws -> Int {
        guard activeTask == nil else { return 0 }
        let eligibleIDs = Set(deviceLocalRemovableSongs(forSourceID: sourceID).map(\.id))
        guard !eligibleIDs.isEmpty else { return 0 }
        let songsToRemove = library.songs.filter {
            eligibleIDs.contains($0.id) && $0.sourceID == sourceID
        }
        guard !songsToRemove.isEmpty else { return 0 }

        let remainingCounts = try library.removeSongsFromThisDevice(
            songsToRemove,
            reason: .remoteDeletionDenied,
            detailsBySongID: deviceLocalRemovalDetails(forSourceID: sourceID)
        )
        for (id, remaining) in remainingCounts {
            sourcesStore.updateLocal(id) { $0.songCount = remaining }
        }
        let removedIDs = Set(songsToRemove.map(\.id))
        lastSourceFailures = lastSourceFailures.compactMap { failure -> SourceFailure? in
            var retained = failure
            retained.retainSongs { !removedIDs.contains($0.id) }
            return retained.songs.isEmpty ? nil : retained
        }
        lastFailedTitles = lastSourceFailures.flatMap { $0.songs.map(\.title) }
        // Not a source deletion: `lastCompletedCount`/`completionRevision` stay
        // untouched so the parent view neither re-presents the failures sheet
        // the dialog just dismissed nor reports these rows as "cleaned".
        deviceLocalRemovalRevision &+= 1
        plog("ℹ️ Duplicate cleanup removed \(songsToRemove.count) song(s) from this device only (source \(sourceID))")
        return songsToRemove.count
    }

    /// Server messages behind each refusal, kept with the ledger entry so the
    /// recovery screen can say why the row is still on the server.
    private func deviceLocalRemovalDetails(forSourceID sourceID: String) -> [String: String] {
        guard let failure = lastSourceFailures.first(where: { $0.id == sourceID }) else {
            return [:]
        }
        return failure.messagesBySongID
    }

    /// 串行删除 songs (按源端逐首)。已有任务进行中时忽略再次触发。
    /// 返回的 Task 不需要 await — 调用方只关心 progress 字段。
    @discardableResult
    func cleanup(_ requestedSongs: [Song]) -> Task<Void, Never>? {
        guard activeTask == nil else { return activeTask }

        // Views filter read-only catalogues before calling this service, but
        // enforce the same boundary here so a future caller can never send an
        // Apple Music/UPnP/server-catalogue row into a source delete attempt.
        let deletableSourceIDs = Set(sourcesStore.sources.lazy
            .filter { $0.type.supportsFileDeletion }
            .map(\.id))
        let songs = requestedSongs.filter { deletableSourceIDs.contains($0.sourceID) }
        if songs.count != requestedSongs.count {
            plog("⚠️ Duplicate cleanup ignored \(requestedSongs.count - songs.count) read-only song(s)")
        }
        guard !songs.isEmpty else { return nil }
        let sourceByID = Dictionary(sourcesStore.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let requestedIDs = Set(songs.map(\.id))
        let currentIDs = Set(library.songs.map(\.id))
        let remainingFailures = lastSourceFailures.compactMap { failure -> SourceFailure? in
            var retained = failure
            retained.retainSongs {
                !requestedIDs.contains($0.id) && currentIDs.contains($0.id)
            }
            return retained.songs.isEmpty ? nil : retained
        }
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

            // 只有源端文件确实被删 (或本就不存在) 的歌才能从库里移除并写
            // tombstone; 删除失败、文件仍在 NAS/云盘上的歌必须保留, 否则它们
            // 会被 tombstone 永久挡掉重扫, 而用户没有恢复入口。
            var removableSongs: [Song] = []
            var failedSongs: [Song] = []
            var failuresBySource = Dictionary(remainingFailures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var failureCount = 0
            var lastProgressPublishAt = Date.distantPast
            let outcomes = await self.sourceManager.deleteSourceFiles(
                for: songs,
                deleteSidecarsForSongIDs: []
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
                if !outcome.result.shouldRemoveLibraryRecord {
                    failureCount += max(outcome.result.failedPaths.count, 1)
                    failedSongs.append(outcome.song)
                    if let source = sourceByID[outcome.song.sourceID] {
                        var failure = failuresBySource[source.id] ?? SourceFailure(source: source, songs: [], reasons: [])
                        failure.songs.append(outcome.song)
                        let songReasons = Set(outcome.result.failedPaths.map(\.reason))
                        failure.reasons.formUnion(songReasons)
                        failure.reasonsBySongID[outcome.song.id, default: []].formUnion(songReasons)
                        if failure.messagesBySongID[outcome.song.id] == nil,
                           let message = outcome.result.failedPaths.first?.message,
                           !message.isEmpty {
                            failure.messagesBySongID[outcome.song.id] = message
                        }
                        failuresBySource[source.id] = failure
                    }
                } else {
                    removableSongs.append(outcome.song)
                }
            }

            if failureCount > 0 {
                plog("⚠️ Duplicate cleanup source deletion failures: \(failureCount) (\(failedSongs.count) songs retained in library)")
            }

            // A selected copy may have survived a permission failure. Plan
            // sidecars only after the actual audio outcomes are known.
            let removedIDs = Set(removableSongs.map(\.id))
            await self.sourceManager.deleteSidecars(
                for: removableSongs,
                retaining: self.library.songs.filter { !removedIDs.contains($0.id) }
            )

            // `primuseSongsRemoved` now performs cache cleanup once for this
            // whole batch. The previous path deleted caches per song here and
            // then deleted the same caches again from that notification.
            // `removableSongs` 只收 `shouldRemoveLibraryRecord` 为真的那些 ——
            // 源端文件确实删掉了(或本来就不存在), 所以墓碑日后可以在同一路径
            // 换了文件时让路。
            let remainingCounts = self.library.deleteSongs(
                removableSongs,
                sourceFileDeleted: true
            )
            for (sourceID, remaining) in remainingCounts {
                self.sourcesStore.updateLocal(sourceID) { $0.songCount = remaining }
            }
            self.lastCompletedCount = removableSongs.count
            self.lastSourceFailures = failuresBySource.values.sorted { $0.source.name < $1.source.name }
            self.lastFailedTitles = self.lastSourceFailures.flatMap { $0.songs.map(\.title) }
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
