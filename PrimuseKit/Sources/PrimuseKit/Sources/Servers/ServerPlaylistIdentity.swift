import Foundation

/// Stable identifiers for playlists mirrored from a server-side music library
/// (Subsonic/Navidrome/Airsonic/gonic, Jellyfin/Emby/Plex).
///
/// The source ID is part of the prefix so two servers of the same kind — or the
/// same server re-added under a new source UUID — never collide, and so pruning
/// one source's stale mirrors cannot touch another's.
public enum ServerPlaylistIdentity {
    public static let playlistIDPrefix = "primuse.system.serverPlaylist."

    /// `primuse.system.serverPlaylist.<sourceID>.<serverPlaylistID>`
    public static func playlistID(sourceID: String, serverPlaylistID: String) -> String {
        "\(playlistIDPrefix)\(sourceID).\(serverPlaylistID)"
    }

    /// Prefix covering every mirror belonging to one source. Passed to
    /// `MusicLibrary.prunePlaylists(withIDPrefix:keepingIDs:)`.
    public static func playlistIDPrefix(sourceID: String) -> String {
        "\(playlistIDPrefix)\(sourceID)."
    }

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID.hasPrefix(playlistIDPrefix)
    }

    /// Recovers the server-native item ID from a `Song.filePath` produced by a
    /// server-library connector: `/songs/<id>.<suffix>` (Subsonic) or
    /// `/items/<id>.<ext>` (Jellyfin/Emby/Plex).
    ///
    /// Playlist entries are matched through this rather than by recomputing the
    /// `Song.id` hash, because that hash includes the file extension and a
    /// playlist response can report a different (or missing) suffix than the
    /// catalogue scan did.
    public static func serverItemID(fromFilePath filePath: String) -> String? {
        let last = (filePath as NSString).lastPathComponent
        guard last.isEmpty == false else { return nil }
        let stripped = (last as NSString).deletingPathExtension
        return stripped.isEmpty ? nil : stripped
    }

    /// 服务端曲目 ID → 本地 `Song.id`, 只收 `wanted` 里的 ID(歌单真正引用到的那些)。
    ///
    /// 给整个源建一份对照, 几十万首的服务器源上就是上百 MB 的临时字典, 而歌单通常只引用
    /// 其中几千首, 没有歌单时一首都用不上。同一个 ID 出现多次(扫描留下的重复行)时第一个
    /// 命中的算数, 与整源对照的结果一致; 要的都找到了就不再往下看。
    /// - Parameter candidates: 这个源的歌, 按曲库顺序给出 `(filePath, songID)`。
    public static func itemIndex<Candidates: Sequence>(
        wanting wanted: Set<String>,
        candidates: Candidates
    ) -> [String: String] where Candidates.Element == (filePath: String, songID: String) {
        guard !wanted.isEmpty else { return [:] }
        var index: [String: String] = [:]
        index.reserveCapacity(wanted.count)
        for candidate in candidates {
            guard let itemID = serverItemID(fromFilePath: candidate.filePath),
                  wanted.contains(itemID),
                  index[itemID] == nil else { continue }
            index[itemID] = candidate.songID
            if index.count == wanted.count { break }
        }
        return index
    }
}

/// Pure reconciliation rule shared by server-playlist sync and its tests.
/// A mirror survives pruning when its detail was synchronized successfully or
/// when the server listed it but its detail fetch failed in this snapshot.
public enum ServerPlaylistReconciliationPolicy {
    public static func mirrorIDsToKeep(
        sourceID: String,
        synchronizedServerPlaylistIDs: [String],
        failedServerPlaylistIDs: Set<String>
    ) -> Set<String> {
        Set(synchronizedServerPlaylistIDs)
            .union(failedServerPlaylistIDs)
            .reduce(into: Set<String>()) { result, serverPlaylistID in
                result.insert(ServerPlaylistIdentity.playlistID(
                    sourceID: sourceID,
                    serverPlaylistID: serverPlaylistID
                ))
            }
    }
}
