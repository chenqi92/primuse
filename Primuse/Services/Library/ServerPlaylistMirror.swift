import Foundation
import PrimuseKit

@MainActor
enum ServerPlaylistMirror {
    struct SyncResult {
        var syncedPlaylistCount = 0
        var matchedTrackCount = 0
        /// 服务端有曲目但本地一首都没匹配上的歌单数。这类歌单被跳过而非清空。
        var unresolvedPlaylistCount = 0
    }

    /// 最近一次同步判定为当前账户不能加歌的镜像歌单。只放内存: 冷启动后几秒
    /// 就会重新同步一次, 在那之前宁可让用户试一次、由服务端拒绝。
    private(set) static var readOnlyPlaylistIDs: Set<String> = []

    static func apply(
        snapshot: ServerPlaylistSnapshot,
        source: MusicSource,
        library: MusicLibrary
    ) -> SyncResult {
        var result = SyncResult()
        let index = serverItemIndex(sourceID: source.id, library: library)
        let context = "Server playlists source=\(LogRedactionPolicy.digest(source.id)) type=\(source.type.rawValue)"
        let prefix = ServerPlaylistIdentity.playlistIDPrefix(sourceID: source.id)
        let previousIDs = Set(library.allPlaylists.filter { $0.id.hasPrefix(prefix) }.map(\.id))
        let suppressedIDs = Set(library.hiddenMirrorPlaylists(forSourceID: source.id).map(\.playlistID))
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
            let playlistContext = "\(context) playlist=\(LogRedactionPolicy.digest(serverPlaylist.id)) received=\(serverPlaylist.trackIDs.count) expected=\(serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count)"
            if serverPlaylist.isReadOnly {
                readOnlyPlaylistIDs.insert(localID)
            } else {
                readOnlyPlaylistIDs.remove(localID)
            }

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
                plog("\(playlistContext) stage=match result=skipped reason=incomplete-detail retained_existing=\(previousIDs.contains(localID))")
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
                plog("\(playlistContext) stage=match result=skipped reason=no-local-match local_indexed_tracks=\(index.count) retained_existing=\(previousIDs.contains(localID))")
                continue
            }

            library.ensurePlaylist(id: localID, name: resolvedName(serverPlaylist.name, localID: localID, library: library))
            library.replaceMirrorPlaylistSongs(
                playlistID: localID,
                songIDs: songIDs,
                coverArtPath: serverPlaylist.coverArtReference
            )
            keepIDs.insert(localID)
            result.syncedPlaylistCount += 1
            result.matchedTrackCount += songIDs.count

            let missingCount = serverPlaylist.trackIDs.filter { index[$0] == nil }.count
            plog("\(playlistContext) stage=match result=applied matched_unique=\(songIDs.count) missing=\(missingCount) hidden_manual=\(suppressedIDs.contains(localID))")
        }

        // 清理服务端已删除的歌单镜像。前缀带 sourceID, 只影响这一个源。
        if snapshot.isIndexComplete {
            library.prunePlaylists(
                withIDPrefix: prefix,
                keepingIDs: keepIDs
            )
        }
        let remainingMirrors = library.allPlaylists.filter { $0.id.hasPrefix(prefix) }
        let remainingIDs = Set(remainingMirrors.filter { !$0.isDeleted }.map(\.id))
        let visibleIDs = Set(library.playlists.map(\.id)).intersection(remainingIDs)
        let manuallyHiddenIDs = remainingIDs.intersection(suppressedIDs)
        let automaticallyHiddenIDs = remainingIDs.subtracting(visibleIDs).subtracting(manuallyHiddenIDs)
        let listedCount = Set(snapshot.playlists.map(\.id)).union(snapshot.failedPlaylistIDs).count
        plog("""
            \(context) stage=apply result=\(snapshot.isIndexComplete ? "complete" : "partial") index_complete=\(snapshot.isIndexComplete) listed=\(listedCount) detailed=\(snapshot.playlists.count) \
            detail_failed=\(snapshot.failedPlaylistIDs.count) applied=\(result.syncedPlaylistCount) \
            unresolved=\(result.unresolvedPlaylistCount) local_indexed_tracks=\(index.count) \
            local=\(remainingIDs.count) visible=\(visibleIDs.count) hidden_manual=\(manuallyHiddenIDs.count) \
            hidden_source=\(automaticallyHiddenIDs.count) suppressions=\(suppressedIDs.count) \
            source_disabled=\(library.disabledSourceIDs.contains(source.id)) pruned=\(previousIDs.subtracting(remainingMirrors.map(\.id)).count)
            """)
        return result
    }

    /// 同步途中每读全一个歌单就先落地, 不必等整轮读完。只新建/覆盖, 从不删除:
    /// 哪些镜像该删只有整轮的快照说了算, 半路中断时已显示的歌单留到下一轮核对。
    /// 取舍与 `apply` 相同 —— 自报数量对不上或一首都没对上的不动。
    @MainActor
    final class ProgressiveApplier {
        private let source: MusicSource
        private let library: MusicLibrary
        /// 同步期间曲库不会因为这一步变化, 建一次给整轮用; 漏掉的新歌由收尾的 `apply` 补上。
        private lazy var index = ServerPlaylistMirror.serverItemIndex(sourceID: source.id, library: library)

        init(source: MusicSource, library: MusicLibrary) {
            self.source = source
            self.library = library
        }

        func apply(_ serverPlaylist: ServerPlaylist) {
            if let reported = serverPlaylist.reportedTrackCount,
               reported > serverPlaylist.trackIDs.count { return }
            let songIDs = ServerPlaylistMirror.uniqued(serverPlaylist.trackIDs.compactMap { index[$0] })
            let serverHasTracks = (serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count) > 0
            if songIDs.isEmpty, serverHasTracks { return }
            let localID = ServerPlaylistIdentity.playlistID(
                sourceID: source.id,
                serverPlaylistID: serverPlaylist.id
            )
            if serverPlaylist.isReadOnly {
                readOnlyPlaylistIDs.insert(localID)
            } else {
                readOnlyPlaylistIDs.remove(localID)
            }
            library.ensurePlaylist(id: localID, name: ServerPlaylistMirror.resolvedName(serverPlaylist.name, localID: localID, library: library))
            library.replaceMirrorPlaylistSongs(
                playlistID: localID,
                songIDs: songIDs,
                coverArtPath: serverPlaylist.coverArtReference
            )
        }
    }

    /// 往服务端歌单加完歌后, 用服务端回读的明细刷新这一个镜像, 不必等下一轮
    /// 整源同步。
    static func applyAppended(
        _ serverPlaylist: ServerPlaylist,
        source: MusicSource,
        library: MusicLibrary
    ) {
        let localID = ServerPlaylistIdentity.playlistID(
            sourceID: source.id,
            serverPlaylistID: serverPlaylist.id
        )
        let index = serverItemIndex(sourceID: source.id, library: library)
        let songIDs = uniqued(serverPlaylist.trackIDs.compactMap { index[$0] })
        guard !songIDs.isEmpty else { return }
        library.ensurePlaylist(id: localID, name: serverPlaylist.name)
        library.replaceMirrorPlaylistSongs(
            playlistID: localID,
            songIDs: songIDs,
            coverArtPath: serverPlaylist.coverArtReference
        )
    }

    private static func resolvedName(_ name: String, localID: String, library: MusicLibrary) -> String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let existing = library.playlist(id: localID)?.name,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return existing }
        return String(localized: "library_folder_apple_music_unnamed_playlist")
    }

    /// 服务端原生 item ID → 本地 `Song.id`。
    ///
    /// 只取该源的歌: 不同源可能有同样的服务端 ID(两个 Navidrome 各自的自增
    /// ID), 混在一起会把歌单指到别的服务器上的歌。
    fileprivate static func serverItemIndex(sourceID: String, library: MusicLibrary) -> [String: String] {
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
    fileprivate static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
