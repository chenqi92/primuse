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
                }
                plog("""
                    ⚠️ Server playlist '\(serverPlaylist.name)' has \
                    \(serverPlaylist.reportedTrackCount ?? serverPlaylist.trackIDs.count) \
                    track(s) on the server but none resolved locally — keeping the existing mirror
                    """)
                continue
            }

            library.ensurePlaylist(id: localID, name: serverPlaylist.name)
            library.replaceMirrorPlaylistSongs(playlistID: localID, songIDs: songIDs)
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
