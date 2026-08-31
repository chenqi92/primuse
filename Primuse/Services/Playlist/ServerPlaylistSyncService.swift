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
    struct SyncResult {
        var syncedPlaylistCount = 0
        var matchedTrackCount = 0
        /// 服务端有曲目但本地一首都没匹配上的歌单数。这类歌单被跳过而非清空。
        var unresolvedPlaylistCount = 0
    }

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

        let index = serverItemIndex(sourceID: source.id, library: library)
        var keepIDs = ServerPlaylistReconciliationPolicy.mirrorIDsToKeep(
            sourceID: source.id,
            synchronizedServerPlaylistIDs: snapshot.playlists.map(\.id),
            failedServerPlaylistIDs: snapshot.failedPlaylistIDs
        )

        for serverPlaylist in snapshot.playlists {
            let localID = ServerPlaylistIdentity.playlistID(
                sourceID: source.id,
                serverPlaylistID: serverPlaylist.id
            )
            let songIDs = uniqued(serverPlaylist.trackIDs.compactMap { index[$0] })

            // 自报数量大于实际明细数量，说明响应仍被服务器截断或分页中途缺页。
            // 这份明细不是权威快照，不能用它覆盖现有镜像的后半段。
            if let reportedTrackCount = serverPlaylist.reportedTrackCount,
               reportedTrackCount > serverPlaylist.trackIDs.count {
                result.unresolvedPlaylistCount += 1
                if library.playlist(id: localID) != nil {
                    library.updateMirrorPlaylistArtwork(
                        playlistID: localID,
                        coverArtPath: serverPlaylist.coverArtReference
                    )
                }
                plog("⚠️ Server playlist '\(serverPlaylist.name)' returned only \(serverPlaylist.trackIDs.count)/\(reportedTrackCount) track IDs — keeping the existing mirror")
                continue
            }

            // 服务端说有曲目, 但本地一首都没匹配上 —— 这是"取不到 / 对不上",
            // 不是"歌单空了"。保留已有镜像原样(存在的话), 也不新建空歌单。
            // 直接 replace 成空会在一次不完整的扫描后把整个歌单清光。
            let serverHasTracks = (serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count) > 0
            if songIDs.isEmpty, serverHasTracks {
                result.unresolvedPlaylistCount += 1
                if library.playlist(id: localID) != nil {
                    // 保住它, 别让 prune 当作"服务端已删"清掉。
                    keepIDs.insert(localID)
                    library.updateMirrorPlaylistArtwork(
                        playlistID: localID,
                        coverArtPath: serverPlaylist.coverArtReference
                    )
                }
                plog("""
                    ⚠️ Server playlist '\(serverPlaylist.name)' has \
                    \(serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count) \
                    track(s) on the server but none resolved locally — keeping the existing mirror
                    """)
                continue
            }

            library.ensurePlaylist(id: localID, name: serverPlaylist.name)
            library.replaceMirrorPlaylistSongs(
                playlistID: localID,
                songIDs: songIDs,
                coverArtPath: serverPlaylist.coverArtReference
            )
            keepIDs.insert(localID)
            result.syncedPlaylistCount += 1
            result.matchedTrackCount += songIDs.count

            let reported = serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count
            if songIDs.count < reported {
                // 部分命中是正常的: 服务端歌单可能含视频 / 未纳入本次扫描范围
                // 的曲目。记下来便于排查, 不阻止写入。
                plog("🎵 Server playlist '\(serverPlaylist.name)' → \(songIDs.count)/\(reported) tracks matched")
            } else {
                plog("🎵 Server playlist '\(serverPlaylist.name)' → \(songIDs.count) tracks")
            }
        }

        // 清理服务端已删除的歌单镜像。前缀带 sourceID, 只影响这一个源。
        library.prunePlaylists(
            withIDPrefix: ServerPlaylistIdentity.playlistIDPrefix(sourceID: source.id),
            keepingIDs: keepIDs
        )
        return result
    }

    /// 服务端原生 item ID → 本地 `Song.id`。
    ///
    /// 只取该源的歌: 不同源可能有同样的服务端 ID(两个 Navidrome 各自的自增
    /// ID), 混在一起会把歌单指到别的服务器上的歌。
    private static func serverItemIndex(sourceID: String, library: MusicLibrary) -> [String: String] {
        var index: [String: String] = [:]
        for song in library.songs where song.sourceID == sourceID {
            guard let itemID = ServerPlaylistIdentity.serverItemID(fromFilePath: song.filePath) else { continue }
            // 首个命中优先; 同一 item ID 重复出现说明扫描产生了重复行, 任取
            // 其一都指向同一服务端曲目。
            if index[itemID] == nil { index[itemID] = song.id }
        }
        return index
    }

    /// 保序去重 —— 服务端歌单允许同一首歌重复出现, 但 `playlistSongs` 以
    /// songID 为键, 重复项会在持久化时被折叠。这里提前去掉, 让写入的顺序
    /// 与最终展示一致。
    private static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
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
