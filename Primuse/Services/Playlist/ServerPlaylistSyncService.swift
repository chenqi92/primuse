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
        library: MusicLibrary
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
        guard let snapshot else { return result }

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

/// Keeps Primuse's liked playlist and Emby's per-user favorite annotations in
/// one state. UI changes are optimistic, but mutations are serialized per
/// source and confirmed by an authoritative refresh. A rejected or ambiguous
/// write is reconciled from Emby when possible and otherwise rolled back.
@MainActor
final class ServerFavoriteSyncService {
    private struct PendingMutation {
        let song: Song
        let itemID: String?
        let previous: Bool
        let desired: Bool
    }

    private let sourceManager: SourceManager
    private let sourcesStore: SourcesStore
    private let library: MusicLibrary
    private weak var player: AudioPlayerService?
    private var pendingMutations: [String: [String: PendingMutation]] = [:]
    private var mutationTasks: [String: Task<Void, Never>] = [:]

    init(
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary,
        player: AudioPlayerService
    ) {
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
        self.player = player
    }

    func localLikedStateDidChange(song: Song, previous: Bool, desired: Bool) {
        guard sourcesStore.sources.contains(where: {
            $0.id == song.sourceID && $0.type == .emby && $0.isEnabled && !$0.isDeleted
        }) else { return }

        var sourceMutations = pendingMutations[song.sourceID] ?? [:]
        sourceMutations[song.id] = PendingMutation(
            song: song,
            itemID: ServerPlaylistIdentity.serverItemID(fromFilePath: song.filePath),
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

    func refresh(source: MusicSource) async {
        guard source.type == .emby else { return }
        do {
            guard let snapshot = try await sourceManager.fetchServerFavorites(for: source) else { return }
            guard mutationTasks[source.id] == nil else { return }
            reconcile(snapshot, sourceID: source.id)
        } catch is CancellationError {
            return
        } catch {
            plog("⚠️ Emby favorite refresh failed for '\(source.name)': \(error.localizedDescription)")
        }
    }

    private func drainMutations(sourceID: String) async {
        while let mutation = takeNextMutation(sourceID: sourceID) {
            do {
                guard let snapshot = try await sourceManager.setServerFavorite(
                    for: mutation.song,
                    isFavorite: mutation.desired
                ) else { continue }
                if hasPendingMutations(sourceID: sourceID) == false {
                    reconcile(snapshot, sourceID: sourceID)
                    player?.republishNowPlayingSurfaces()
                }
            } catch is CancellationError {
                if pendingMutations[sourceID]?[mutation.song.id] == nil {
                    rollbackIfCurrent(mutation)
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
        if pendingMutations[sourceID]?[mutation.song.id] != nil {
            return
        }

        let recoveredSnapshot = try? await sourceManager.fetchServerFavorites(sourceID: sourceID)
        if pendingMutations[sourceID]?[mutation.song.id] != nil {
            return
        }

        if let snapshot = recoveredSnapshot {
            let serverValue = mutation.itemID.map { snapshot.itemIDs.contains($0) } ?? mutation.previous
            if hasPendingMutations(sourceID: sourceID) {
                library.setLiked(
                    songID: mutation.song.id,
                    isLiked: serverValue,
                    propagatesServerMutation: false
                )
            } else {
                reconcile(snapshot, sourceID: sourceID)
            }
            player?.republishNowPlayingSurfaces()
            if serverValue == mutation.desired {
                return
            }
        } else {
            rollbackIfCurrent(mutation)
        }

        library.presentServerFavoriteError(String(
            format: String(localized: "server_favorite_update_failed_message"),
            error.localizedDescription
        ))
    }

    private func rollbackIfCurrent(_ mutation: PendingMutation) {
        guard library.isLiked(songID: mutation.song.id) == mutation.desired else { return }
        library.setLiked(
            songID: mutation.song.id,
            isLiked: mutation.previous,
            propagatesServerMutation: false
        )
        player?.republishNowPlayingSurfaces()
    }

    private func reconcile(_ snapshot: ServerFavoriteSnapshot, sourceID: String) {
        var songsByServerItemID: [String: String] = [:]
        for song in library.songs where song.sourceID == sourceID {
            guard let itemID = ServerPlaylistIdentity.serverItemID(fromFilePath: song.filePath),
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
}
