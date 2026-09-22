import Foundation
import PrimuseKit

/// 把服务端曲库源上的用户歌单同步成本地镜像歌单。
///
/// 与 m3u8 导入不同, 这里不需要文件名 / 标题模糊匹配: 服务端曲库连接器把
/// 服务端原生 item ID 编进 `Song.filePath`(`/songs/<id>.<suffix>` 或
/// `/items/<id>.<ext>`), 所以歌单曲目能按 ID 精确命中。
///
/// 镜像语义(与 Apple Music 资料库镜像一致): 歌单 ID 由 sourceID + 服务端歌单
/// ID 派生, 每次扫描后用服务端内容覆盖, 用户在 Primuse 侧的改动不回写服务端。
@MainActor
enum ServerPlaylistSyncService {
    typealias SyncResult = ServerPlaylistMirror.SyncResult

    /// 扫描完成后调用。任何失败都只记日志 —— 歌单同步是曲库扫描的附加步骤,
    /// 不该让已经成功的扫描显示为失败。
    @discardableResult
    static func sync(
        source: MusicSource,
        sourceManager: SourceManager,
        library: MusicLibrary,
        applyFence: ServerMirrorApplyFence = { true }
    ) async -> SyncResult {
        var result = SyncResult()
        guard source.type.isServerLibrary else { return result }

        let snapshot: ServerPlaylistSnapshot?
        do {
            snapshot = try await sourceManager.fetchServerPlaylists(for: source)
        } catch is CancellationError {
            return result
        } catch {
            plog("⚠️ Server playlist sync failed for '\(source.name)': \(error.localizedDescription)")
            return result
        }
        // nil = 该源类型没有歌单能力, 不要动本地任何东西。
        guard let snapshot, applyFence() else { return result }

        result = ServerPlaylistMirror.apply(snapshot: snapshot, source: source, library: library)
        // 服务端一个歌单都没返回时下面一条日志都不会有, 与"请求失败"和"歌单里的
        // 歌在本地一首都对不上"分不开。这一行把三种结果区分开。
        plog("""
            🎵 Server playlists '\(source.name)': listed \(snapshot.playlists.count), \
            mirrored \(result.syncedPlaylistCount), unresolved \(result.unresolvedPlaylistCount), \
            detail failed \(snapshot.failedPlaylistIDs.count)
            """)
        return result
    }
}

@MainActor
protocol ServerFavoriteManaging: AnyObject {
    func fetchServerFavorites(for source: MusicSource) async throws -> ServerFavoriteSnapshot?
    func fetchServerFavorites(sourceID: String) async throws -> ServerFavoriteSnapshot?
    func setServerFavorite(
        for song: Song,
        source: MusicSource,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot?
}

extension SourceManager: ServerFavoriteManaging {}

@MainActor
protocol ServerFavoriteSourcesProviding: AnyObject {
    func source(id: String) -> MusicSource?
}

extension SourcesStore: ServerFavoriteSourcesProviding {}

@MainActor
protocol ServerFavoriteLibraryManaging: AnyObject {
    var songs: [Song] { get }
    func isLiked(songID: String) -> Bool
    func setLiked(songID: String, isLiked: Bool, propagatesServerMutation: Bool)
    func replaceLikedSongs(fromSourceID sourceID: String, with authoritativeSongIDs: [String])
    func presentServerFavoriteError(_ message: String)
}

extension MusicLibrary: ServerFavoriteLibraryManaging {}

@MainActor
protocol ServerFavoriteSurfacePublishing: AnyObject {
    func republishNowPlayingSurfaces()
}

extension AudioPlayerService: ServerFavoriteSurfacePublishing {}

/// Keeps Primuse's liked playlist and supported server favorite annotations in
/// one state. UI changes are optimistic, but mutations are serialized per
/// source and confirmed by an authoritative refresh. A rejected or ambiguous
/// write is reconciled from the server when possible and otherwise rolled back
/// to the last state that was authoritatively confirmed.
@MainActor
final class ServerFavoriteSyncService {
    private struct PendingMutation {
        let song: Song
        let source: MusicSource
        let sourceScopeFingerprint: String
        let itemID: String
        let sourceType: MusicSourceType
        let previous: Bool
        let desired: Bool
    }

    private struct ScopedConfirmedStates {
        let sourceScopeFingerprint: String
        var valuesBySongID: [String: Bool]
    }

    private let sourceManager: any ServerFavoriteManaging
    private let sourcesStore: any ServerFavoriteSourcesProviding
    private let library: any ServerFavoriteLibraryManaging
    private weak var player: (any ServerFavoriteSurfacePublishing)?
    private var pendingMutations: [String: [String: PendingMutation]] = [:]
    private var mutationTasks: [String: Task<Void, Never>] = [:]
    private var mutationRevisions: [String: UInt64] = [:]
    /// Last state confirmed by a mutation response or recovery read. Each
    /// bucket is bound to one complete account/security scope and spans a
    /// rapid sequence for one song, so stale work cannot roll back a new
    /// account to another optimistic UI value.
    private var confirmedStates: [String: ScopedConfirmedStates] = [:]

    init(
        sourceManager: any ServerFavoriteManaging,
        sourcesStore: any ServerFavoriteSourcesProviding,
        library: any ServerFavoriteLibraryManaging,
        player: any ServerFavoriteSurfacePublishing
    ) {
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
        self.player = player
    }

    func localLikedStateDidChange(song: Song, previous: Bool, desired: Bool) {
        mutationRevisions[song.sourceID, default: 0] &+= 1
        guard let source = sourcesStore.source(id: song.sourceID),
              ServerFavoriteWritebackPolicy.supports(source.type) else { return }
        guard source.isEnabled, !source.isDeleted else {
            failImmediately(
                song: song,
                previous: previous,
                desired: desired,
                error: SourceError.fileNotFound("Source not found for favorite update")
            )
            return
        }
        guard let itemID = ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) else {
            failImmediately(
                song: song,
                previous: previous,
                desired: desired,
                error: SourceError.fileNotFound(String(localized: "server_favorite_missing_song_id"))
            )
            return
        }

        let sourceScopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        if confirmedState(
            sourceID: song.sourceID,
            sourceScopeFingerprint: sourceScopeFingerprint,
            songID: song.id
        ) == nil {
            setConfirmedState(
                previous,
                sourceID: song.sourceID,
                sourceScopeFingerprint: sourceScopeFingerprint,
                songID: song.id
            )
        }

        var sourceMutations = pendingMutations[song.sourceID] ?? [:]
        sourceMutations[song.id] = PendingMutation(
            song: song,
            source: source,
            sourceScopeFingerprint: sourceScopeFingerprint,
            itemID: itemID,
            sourceType: source.type,
            previous: previous,
            desired: desired
        )
        pendingMutations[song.sourceID] = sourceMutations

        guard mutationTasks[song.sourceID] == nil else { return }
        let sourceID = song.sourceID
        mutationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainMutations(sourceID: sourceID)
            self.mutationTasks[sourceID] = nil
        }
    }

    func refresh(
        source: MusicSource,
        applyFence: ServerMirrorApplyFence = { true }
    ) async {
        guard ServerFavoriteWritebackPolicy.supports(source.type),
              source.isEnabled, !source.isDeleted else { return }
        guard mutationTasks[source.id] == nil else { return }
        let sourceScopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        guard sourceScopeIsCurrent(
            sourceID: source.id,
            expectedFingerprint: sourceScopeFingerprint
        ) else { return }
        let mutationRevision = mutationRevisions[source.id, default: 0]
        do {
            guard let snapshot = try await sourceManager.fetchServerFavorites(for: source) else { return }
            guard applyFence(),
                  mutationTasks[source.id] == nil,
                  sourceScopeIsCurrent(
                      sourceID: source.id,
                      expectedFingerprint: sourceScopeFingerprint
                  ),
                  mutationRevisions[source.id, default: 0] == mutationRevision else { return }
            reconcile(snapshot, sourceID: source.id, sourceType: source.type)
            clearConfirmedStates(
                sourceID: source.id,
                sourceScopeFingerprint: sourceScopeFingerprint
            )
        } catch is CancellationError {
            return
        } catch {
            plog("⚠️ Server favorite refresh failed for '\(source.name)': \(error.localizedDescription)")
        }
    }

    func waitForPendingMutations(sourceID: String) async {
        while let task = mutationTasks[sourceID] {
            await task.value
        }
    }

    private func drainMutations(sourceID: String) async {
        while let mutation = takeNextMutation(sourceID: sourceID) {
            guard mutationScopeIsCurrent(mutation) else {
                discardStaleMutationState(mutation, sourceID: sourceID)
                continue
            }
            do {
                guard let snapshot = try await sourceManager.setServerFavorite(
                    for: mutation.song,
                    source: mutation.source,
                    isFavorite: mutation.desired
                ) else {
                    throw SourceError.connectionFailed(String(localized: "server_favorite_unsupported"))
                }
                guard mutationScopeIsCurrent(mutation) else {
                    discardStaleMutationState(mutation, sourceID: sourceID)
                    continue
                }
                try accept(snapshot, for: mutation, sourceID: sourceID)
            } catch is CancellationError {
                if !hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
                    if mutationScopeIsCurrent(mutation) {
                        rollbackToConfirmedState(mutation, sourceID: sourceID)
                    } else {
                        discardStaleMutationState(mutation, sourceID: sourceID)
                    }
                }
            } catch {
                await recover(mutation, error: error, sourceID: sourceID)
            }
        }
    }

    private func recover(
        _ mutation: PendingMutation,
        error: Error,
        sourceID: String
    ) async {
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        let recoveredSnapshot = try? await sourceManager.fetchServerFavorites(
            for: mutation.source
        )
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        if let snapshot = recoveredSnapshot {
            let serverValue = snapshot.itemIDs.contains(mutation.itemID)
            setConfirmedState(
                serverValue,
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                songID: mutation.song.id
            )

            if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
                return
            }
            if hasPendingMutations(sourceID: sourceID) {
                library.setLiked(
                    songID: mutation.song.id,
                    isLiked: serverValue,
                    propagatesServerMutation: false
                )
                clearConfirmedState(
                    sourceID: sourceID,
                    sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                    songID: mutation.song.id
                )
            } else {
                reconcile(snapshot, sourceID: sourceID, sourceType: mutation.sourceType)
                clearConfirmedStates(
                    sourceID: sourceID,
                    sourceScopeFingerprint: mutation.sourceScopeFingerprint
                )
            }
            player?.republishNowPlayingSurfaces()
            if serverValue == mutation.desired {
                return
            }
        } else if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
            return
        } else {
            rollbackToConfirmedState(mutation, sourceID: sourceID)
        }

        presentFailure(error)
    }

    private func accept(
        _ snapshot: ServerFavoriteSnapshot,
        for mutation: PendingMutation,
        sourceID: String
    ) throws {
        let serverValue = snapshot.itemIDs.contains(mutation.itemID)
        guard serverValue == mutation.desired else {
            throw SourceError.connectionFailed(String(localized: "server_favorite_refresh_mismatch"))
        }
        setConfirmedState(
            serverValue,
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )

        if hasPendingMutation(sourceID: sourceID, songID: mutation.song.id) {
            return
        }
        if hasPendingMutations(sourceID: sourceID) {
            library.setLiked(
                songID: mutation.song.id,
                isLiked: serverValue,
                propagatesServerMutation: false
            )
            clearConfirmedState(
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint,
                songID: mutation.song.id
            )
        } else {
            reconcile(snapshot, sourceID: sourceID, sourceType: mutation.sourceType)
            clearConfirmedStates(
                sourceID: sourceID,
                sourceScopeFingerprint: mutation.sourceScopeFingerprint
            )
        }
        player?.republishNowPlayingSurfaces()
    }

    private func rollbackToConfirmedState(_ mutation: PendingMutation, sourceID: String) {
        guard mutationScopeIsCurrent(mutation) else {
            discardStaleMutationState(mutation, sourceID: sourceID)
            return
        }
        let confirmed = confirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
            ?? mutation.previous
        let shouldRollback = library.isLiked(songID: mutation.song.id) == mutation.desired
        if shouldRollback {
            library.setLiked(
                songID: mutation.song.id,
                isLiked: confirmed,
                propagatesServerMutation: false
            )
        }
        clearConfirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
        if shouldRollback {
            player?.republishNowPlayingSurfaces()
        }
    }

    private func reconcile(
        _ snapshot: ServerFavoriteSnapshot,
        sourceID: String,
        sourceType: MusicSourceType
    ) {
        var songsByServerItemID: [String: String] = [:]
        for song in library.songs where song.sourceID == sourceID {
            guard let itemID = ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: song.filePath,
                sourceType: sourceType
            ),
                  songsByServerItemID[itemID] == nil else { continue }
            songsByServerItemID[itemID] = song.id
        }
        library.replaceLikedSongs(
            fromSourceID: sourceID,
            with: snapshot.itemIDs.compactMap { songsByServerItemID[$0] }
        )
    }

    private func takeNextMutation(sourceID: String) -> PendingMutation? {
        guard var sourceMutations = pendingMutations[sourceID],
              let songID = sourceMutations.keys.first,
              let mutation = sourceMutations.removeValue(forKey: songID) else { return nil }
        if sourceMutations.isEmpty {
            pendingMutations.removeValue(forKey: sourceID)
        } else {
            pendingMutations[sourceID] = sourceMutations
        }
        return mutation
    }

    private func hasPendingMutations(sourceID: String) -> Bool {
        pendingMutations[sourceID]?.isEmpty == false
    }

    private func hasPendingMutation(sourceID: String, songID: String) -> Bool {
        pendingMutations[sourceID]?[songID] != nil
    }

    private func mutationScopeIsCurrent(_ mutation: PendingMutation) -> Bool {
        sourceScopeIsCurrent(
            sourceID: mutation.song.sourceID,
            expectedFingerprint: mutation.sourceScopeFingerprint
        )
    }

    private func sourceScopeIsCurrent(
        sourceID: String,
        expectedFingerprint: String
    ) -> Bool {
        guard let current = sourcesStore.source(id: sourceID),
              current.isEnabled,
              !current.isDeleted else { return false }
        return MusicSourceSecurityRevision.scopedFingerprint(for: current)
            == expectedFingerprint
    }

    private func discardStaleMutationState(_ mutation: PendingMutation, sourceID: String) {
        clearConfirmedState(
            sourceID: sourceID,
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            songID: mutation.song.id
        )
    }

    private func confirmedState(
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) -> Bool? {
        guard let sourceStates = confirmedStates[sourceID],
              sourceStates.sourceScopeFingerprint == sourceScopeFingerprint else { return nil }
        return sourceStates.valuesBySongID[songID]
    }

    private func setConfirmedState(
        _ value: Bool,
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) {
        var sourceStates: ScopedConfirmedStates
        if let existing = confirmedStates[sourceID],
           existing.sourceScopeFingerprint == sourceScopeFingerprint {
            sourceStates = existing
        } else {
            sourceStates = ScopedConfirmedStates(
                sourceScopeFingerprint: sourceScopeFingerprint,
                valuesBySongID: [:]
            )
        }
        sourceStates.valuesBySongID[songID] = value
        confirmedStates[sourceID] = sourceStates
    }

    private func clearConfirmedState(
        sourceID: String,
        sourceScopeFingerprint: String,
        songID: String
    ) {
        guard var sourceStates = confirmedStates[sourceID],
              sourceStates.sourceScopeFingerprint == sourceScopeFingerprint else { return }
        sourceStates.valuesBySongID.removeValue(forKey: songID)
        if sourceStates.valuesBySongID.isEmpty {
            confirmedStates.removeValue(forKey: sourceID)
        } else {
            confirmedStates[sourceID] = sourceStates
        }
    }

    private func clearConfirmedStates(
        sourceID: String,
        sourceScopeFingerprint: String
    ) {
        guard confirmedStates[sourceID]?.sourceScopeFingerprint == sourceScopeFingerprint else {
            return
        }
        confirmedStates.removeValue(forKey: sourceID)
    }

    private func failImmediately(
        song: Song,
        previous: Bool,
        desired: Bool,
        error: Error
    ) {
        guard library.isLiked(songID: song.id) == desired else { return }
        library.setLiked(
            songID: song.id,
            isLiked: previous,
            propagatesServerMutation: false
        )
        player?.republishNowPlayingSurfaces()
        presentFailure(error)
    }

    private func presentFailure(_ error: Error) {
        library.presentServerFavoriteError(String(
            format: String(localized: "server_favorite_update_failed_message"),
            error.localizedDescription
        ))
    }
}

/// 把服务端镜像(歌单 /「喜欢」/ 电台)的刷新从曲库扫描里拆出来。
///
/// 这三样原本只在 `ScanService` 的扫描收尾里跑。媒体服务器这类源又没有任何自动
/// 重扫 —— 目录探针只认 Subsonic 系(`ServerCatalogAutoRefreshPolicy`), 周期
/// 同步只认三家网盘(`SourcePeriodicSyncPolicy`), 启动只续接断了的扫描 —— 于是
/// 用户在 Emby 上新建的歌单要等他自己想起来去「音乐源」里手动扫一次才会出现;
/// Subsonic 系则要等到曲库真的多了歌、探针判定需要重扫才捎带上(#142)。
///
/// 曲库没变也该能看到服务器上新建的歌单, 所以这里按源单独刷一次: 冷启动一次,
/// 回到前台且过了冷却再一次。只发歌单 / 收藏 / 电台这几个小请求, 不遍历曲库,
/// 也不改任何扫描状态。
@MainActor
final class ServerMirrorRefreshCoordinator {
    /// 一次刷新要按歌单逐个拉明细, 比目录探针的一个请求贵, 冷却也给得更长。
    static let cooldown: TimeInterval = 30 * 60
    /// 与目录探针一样避开首屏: 启动这几秒的网络留给正在播的那首歌。
    private static let launchDelay: Duration = .seconds(6)

    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private let library: MusicLibrary
    private let scanService: ScanService
    private let refreshMirrors: (MusicSource, ServerMirrorApplyFence) async -> Void

    /// 发起时间, 不是成功时间: 连不上的服务器也要按冷却退避, 否则每次切回前台
    /// 都要在超时上等一轮。
    private var lastRefreshStartedAt: [String: Date] = [:]
    private var runningTask: Task<Void, Never>?
    private var didScheduleColdLaunch = false

    init(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary,
        scanService: ScanService,
        refreshMirrors: @escaping (MusicSource, ServerMirrorApplyFence) async -> Void
    ) {
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
        self.library = library
        self.scanService = scanService
        self.refreshMirrors = refreshMirrors
    }

    func startColdLaunchRefresh() {
        guard !didScheduleColdLaunch else { return }
        didScheduleColdLaunch = true
        start(after: Self.launchDelay)
    }

    func applicationDidBecomeActive() {
        // 冷启动那一轮还没排上就别插队, 它自己会跑。
        guard didScheduleColdLaunch else { return }
        start(after: .zero)
    }

    private func start(after delay: Duration) {
        guard runningTask == nil else { return }
        runningTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            // 清干净再返回: 漏掉一次就再也没有下一轮了。
            defer { self.runningTask = nil }
            guard !Task.isCancelled else { return }
            // 库还在准备时 `library.songs` 是空的, 服务端歌单会被整份判成
            // "一首都对不上"而不建 —— 等发布完再对。
            await self.library.whenReady()
            await self.refreshDueSources()
        }
    }

    private func refreshDueSources() async {
        for source in sourcesStore.sources {
            guard !Task.isCancelled else { return }
            let now = Date()
            guard isDue(source, now: now) else { continue }
            lastRefreshStartedAt[source.id] = now

            // 刷新期间源被停用 / 删除 / 改了凭据, 或者扫描接手了这个源, 拿回来的
            // 快照就不该再落地 —— 与扫描收尾用的是同一道闸。
            let scopeFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
            let sourceID = source.id
            let applyFence: ServerMirrorApplyFence = { [weak self] in
                guard let self,
                      let current = self.sourcesStore.source(id: sourceID),
                      current.isEnabled,
                      !current.isDeleted,
                      MusicSourceSecurityRevision.scopedFingerprint(for: current) == scopeFingerprint,
                      self.scanService.scanStates[sourceID]?.isScanning != true else { return false }
                return true
            }
            guard applyFence() else { continue }
            await refreshMirrors(source, applyFence)
        }
    }

    private func isDue(_ source: MusicSource, now: Date) -> Bool {
        guard source.type.isServerLibrary, source.isEnabled, !source.isDeleted else { return false }
        // 还没扫过的源本地没有歌可对, 歌单只会被判成"对不上"而不建。等它先扫一次。
        guard source.lastScannedAt != nil || source.songCount > 0 else { return false }
        // 扫描收尾会做同一件事, 别和它抢。
        guard scanService.scanStates[source.id]?.isScanning != true else { return false }
        // 当前网络路径下这个源的每个地址都探测失败过, 现在去连只会白等一轮超时。
        guard !sourceManager.unreachablePlaybackSourceIDs.contains(source.id) else { return false }
        guard let last = lastRefreshStartedAt[source.id] else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }
}
