import Foundation
import PrimuseKit

@MainActor
enum ServerPlaylistMirror {
    struct SyncResult {
        /// 已同步名称和封面的歌单数，包含曲目仍待匹配的歌单。
        var syncedPlaylistCount = 0
        var matchedTrackCount = 0
        /// 服务端有曲目但本地一首都没匹配上的歌单数，只更新名称和封面，保留已有曲目。
        var unresolvedPlaylistCount = 0
    }

    /// 最近一次同步判定为当前账户不能加歌的镜像歌单。只放内存: 冷启动后几秒
    /// 就会重新同步一次, 在那之前宁可让用户试一次、由服务端拒绝。
    private(set) static var readOnlyPlaylistIDs: Set<String> = []

    /// 服务端曲目 → 本地歌曲的对照结果。只由值算出(这个源的歌 + 服务端快照),
    /// 可以在主线程外算好, 主线程只做落地。
    struct PreparedSnapshot: Sendable {
        fileprivate struct Entry: Sendable {
            let serverPlaylist: ServerPlaylist
            let localID: String
            let songIDs: [String]
            let missingCount: Int
            let logContext: String
        }
        fileprivate let entries: [Entry]
        fileprivate let indexedTrackCount: Int
    }

    static func apply(
        snapshot: ServerPlaylistSnapshot,
        source: MusicSource,
        library: MusicLibrary
    ) -> SyncResult {
        let prepared = prepare(
            snapshot: snapshot,
            sourceID: source.id,
            sourceType: source.type,
            songs: library.songs
        )
        return apply(prepared, snapshot: snapshot, source: source, library: library)
    }

    /// 整库建索引、逐首对照放到主线程外: 几万首的曲库加上几十个歌单, 在主线程上
    /// 要卡一百多毫秒, 正好赶上冷启动后首页出现。回来之后调用方要重新过闸。
    static func prepareOffMain(
        snapshot: ServerPlaylistSnapshot,
        source: MusicSource,
        library: MusicLibrary
    ) async -> PreparedSnapshot {
        let songs = library.songs
        let sourceID = source.id
        let sourceType = source.type
        return await Task.detached(priority: .utility) {
            ServerPlaylistMirror.prepare(snapshot: snapshot, sourceID: sourceID, sourceType: sourceType, songs: songs)
        }.value
    }

    nonisolated private static func prepare(
        snapshot: ServerPlaylistSnapshot,
        sourceID: String,
        sourceType: MusicSourceType,
        songs: [Song]
    ) -> PreparedSnapshot {
        let index = serverItemIndex(sourceID: sourceID, songs: songs)
        let context = logContext(sourceID: sourceID, sourceType: sourceType)
        let entries = snapshot.playlists.map { serverPlaylist in
            // 一遍走完: 保序去重, 顺带数出对不上的条目。
            var songIDs: [String] = []
            songIDs.reserveCapacity(serverPlaylist.trackIDs.count)
            var seen = Set<String>()
            var missingCount = 0
            for trackID in serverPlaylist.trackIDs {
                guard let songID = index[trackID] else {
                    missingCount += 1
                    continue
                }
                if seen.insert(songID).inserted { songIDs.append(songID) }
            }
            return PreparedSnapshot.Entry(
                serverPlaylist: serverPlaylist,
                localID: ServerPlaylistIdentity.playlistID(
                    sourceID: sourceID,
                    serverPlaylistID: serverPlaylist.id
                ),
                songIDs: songIDs,
                missingCount: missingCount,
                logContext: "\(context) playlist=\(LogRedactionPolicy.digest(serverPlaylist.id)) received=\(serverPlaylist.trackIDs.count) expected=\(serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count)"
            )
        }
        return PreparedSnapshot(entries: entries, indexedTrackCount: index.count)
    }

    nonisolated private static func logContext(sourceID: String, sourceType: MusicSourceType) -> String {
        "Server playlists source=\(LogRedactionPolicy.digest(sourceID)) type=\(sourceType.rawValue)"
    }

    static func apply(
        _ prepared: PreparedSnapshot,
        snapshot: ServerPlaylistSnapshot,
        source: MusicSource,
        library: MusicLibrary
    ) -> SyncResult {
        var result = SyncResult()
        let context = logContext(sourceID: source.id, sourceType: source.type)
        let prefix = ServerPlaylistIdentity.playlistIDPrefix(sourceID: source.id)
        let previousIDs = Set(library.allPlaylists.filter { $0.id.hasPrefix(prefix) }.map(\.id))
        let suppressedIDs = Set(library.hiddenMirrorPlaylists(forSourceID: source.id).map(\.playlistID))
        var keepIDs = ServerPlaylistReconciliationPolicy.mirrorIDsToKeep(
            sourceID: source.id,
            synchronizedServerPlaylistIDs: snapshot.playlists.map(\.id),
            failedServerPlaylistIDs: snapshot.failedPlaylistIDs
        )

        for entry in prepared.entries {
            let serverPlaylist = entry.serverPlaylist
            let localID = entry.localID
            let songIDs = entry.songIDs
            let playlistContext = entry.logContext
            if serverPlaylist.isReadOnly {
                readOnlyPlaylistIDs.insert(localID)
            } else {
                readOnlyPlaylistIDs.remove(localID)
            }

            library.ensurePlaylist(id: localID, name: resolvedName(serverPlaylist.name, localID: localID, library: library))
            keepIDs.insert(localID)
            result.syncedPlaylistCount += 1

            // 自报数量比实际给出的多(服务器把读不出、已失效的条目也算进去)时,
            // 照样用读到的这些: 翻页缺页由各来源自己翻页时判出并整份算作失败,
            // 能走到这里的明细就是服务器这次给得出的全部。以前整张跳过, 一张
            // 歌单里有一首坏掉的歌就再也同步不过来。

            // 服务端说有曲目, 但本地一首都没匹配上 —— 这是"取不到 / 对不上",
            // 不是"歌单空了"。名称和封面照常同步，歌曲等待后续扫描补齐；
            // 直接 replace 成空会在一次不完整的扫描后把已有歌单清光。
            let serverHasTracks = Self.serverHasTracks(serverPlaylist)
            if songIDs.isEmpty, serverHasTracks {
                result.unresolvedPlaylistCount += 1
                library.updateMirrorPlaylistArtwork(
                    playlistID: localID,
                    coverArtPath: serverPlaylist.coverArtReference
                )
                plog("\(playlistContext) stage=match result=metadata-only reason=no-local-match local_indexed_tracks=\(prepared.indexedTrackCount) retained_existing=\(previousIDs.contains(localID))")
                continue
            }

            library.replaceMirrorPlaylistSongs(
                playlistID: localID,
                songIDs: songIDs,
                coverArtPath: serverPlaylist.coverArtReference
            )
            result.matchedTrackCount += songIDs.count

            plog("\(playlistContext) stage=match result=applied matched_unique=\(songIDs.count) missing=\(entry.missingCount) hidden_manual=\(suppressedIDs.contains(localID))")
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
            unresolved=\(result.unresolvedPlaylistCount) local_indexed_tracks=\(prepared.indexedTrackCount) \
            local=\(remainingIDs.count) visible=\(visibleIDs.count) hidden_manual=\(manuallyHiddenIDs.count) \
            hidden_source=\(automaticallyHiddenIDs.count) suppressions=\(suppressedIDs.count) \
            source_disabled=\(library.disabledSourceIDs.contains(source.id)) pruned=\(previousIDs.subtracting(remainingMirrors.map(\.id)).count)
            """)
        return result
    }

    /// 同步途中每读全一个歌单就先落地, 不必等整轮读完。只新建/覆盖, 从不删除:
    /// 哪些镜像该删只有整轮的快照说了算, 半路中断时已显示的歌单留到下一轮核对。
    /// 取舍与 `apply` 相同 —— 曲目未匹配时只同步名称和封面，保留已有曲目。
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
            let songIDs = ServerPlaylistMirror.uniqued(serverPlaylist.trackIDs.compactMap { index[$0] })
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
            if songIDs.isEmpty, ServerPlaylistMirror.serverHasTracks(serverPlaylist) {
                library.updateMirrorPlaylistArtwork(
                    playlistID: localID,
                    coverArtPath: serverPlaylist.coverArtReference
                )
                return
            }
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
        library.ensurePlaylist(id: localID, name: resolvedName(serverPlaylist.name, localID: localID, library: library))
        library.replaceMirrorPlaylistSongs(
            playlistID: localID,
            songIDs: songIDs,
            coverArtPath: serverPlaylist.coverArtReference
        )
    }

    /// 刚在服务端建好的歌单先落一个空镜像: 接下来加歌要是失败了, 再复制一次会认出这个同名
    /// 歌单往里加, 不会在服务器上再建一个。
    static func applyCreated(
        _ serverPlaylist: ServerPlaylist,
        source: MusicSource,
        library: MusicLibrary
    ) {
        let localID = ServerPlaylistIdentity.playlistID(
            sourceID: source.id,
            serverPlaylistID: serverPlaylist.id
        )
        library.ensurePlaylist(id: localID, name: resolvedName(serverPlaylist.name, localID: localID, library: library))
    }

    /// 自报数量与实际给出的条目, 任一说有就算有: 自报数量缺省、写成 0 或比实际少时,
    /// 不能因此把"一首都没对上"当成"歌单空了"去清空现有镜像。
    fileprivate static func serverHasTracks(_ serverPlaylist: ServerPlaylist) -> Bool {
        max(serverPlaylist.reportedTrackCount ?? 0, serverPlaylist.trackIDs.count) > 0
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
        serverItemIndex(sourceID: sourceID, songs: library.songs)
    }

    nonisolated private static func serverItemIndex(sourceID: String, songs: [Song]) -> [String: String] {
        var index: [String: String] = [:]
        for song in songs where song.sourceID == sourceID {
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
